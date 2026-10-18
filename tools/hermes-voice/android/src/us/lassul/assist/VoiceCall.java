package us.lassul.assist;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;
import org.webrtc.DataChannel;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RtpReceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.audio.JavaAudioDeviceModule;

/**
 * One call with gpt-live-1 over WebRTC, delegating to Hermes through hermes-voice: the web page's
 * Call (static/app.js) in Java, with the same events, delegation, voice approvals, end_call and
 * idle rules. Lives on the main thread; WebRTC and network callbacks are posted to it.
 */
final class VoiceCall {
    interface Listener {
        /** The voice model listens (session.started). */
        void onListening();

        /** The call is over; the reason is for the log. */
        void onFinished(String reason, boolean failed);
    }

    // The voice model accepts at most 500 tokens per append; ~4 chars per token.
    private static final int APPEND_CHAR_LIMIT = 1400;
    // Transcript deltas can trail the delegation event; wait for the last words.
    private static final long DELEGATION_SETTLE_MS = 400;
    // Once Hermes ended the call (end_call item), the call closes when the voice has been quiet
    // this long after speaking the reply, at the latest after END_CALL_MAX_MS.
    private static final long END_CALL_QUIET_MS = 800;
    private static final long END_CALL_MAX_MS = 30_000;
    private static final long CLOSE_TIMEOUT_MS = 15_000;
    // Trickle is fine: the vendor answers with the candidates it has.
    private static final long ICE_TIMEOUT_MS = 3_000;
    private static final long TICK_MS = 100;
    // The voice counts as speaking while a sample above this came within SPEAKING_HOLD_MS.
    private static final int SPEAKING_PEAK = 1500;
    private static final long SPEAKING_HOLD_MS = 400;
    // Spoken answer to an approval question. Denials win, so "no, don't do it" never approves;
    // anything unclear is asked again.
    private static final Pattern DENY = Pattern.compile(
            "\\b(no|nope|deny|denied|don'?t|do not|stop|cancel|abort|reject|nein|nicht)\\b",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern APPROVE = Pattern.compile(
            "\\b(yes|yeah|yep|approve|approved|go ahead|do it|okay|ok|sure|confirm|allow|ja)\\b",
            Pattern.CASE_INSENSITIVE);

    private static boolean webrtcLoaded;

    private final Context context;
    private final Api api;
    private final Conversation conversation;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newCachedThreadPool();

    private JavaAudioDeviceModule audio;
    private PeerConnectionFactory factory;
    private PeerConnection pc;
    private AudioSource source;
    private AudioTrack mic;
    private DataChannel events;
    private boolean offerSent;
    private long idleMs = 90_000;

    // Written by WebRTC's audio thread, read by tick().
    private volatile long lastLoud;
    private long lastActivity = SystemClock.elapsedRealtime();
    private boolean speaking;
    private String lastSpeaker;
    private Delegation delegation;
    private Approval approval;
    private boolean closed;
    private boolean closing;
    private boolean ending;
    private boolean endingSpoken;
    private int eventCounter;
    private double usageSeconds;

    private final Runnable sendOffer = new Runnable() {
        @Override
        public void run() {
            sendOffer();
        }
    };
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            tick();
        }
    };
    private final Runnable closeTimedOut = new Runnable() {
        @Override
        public void run() {
            finish("close timed out", false);
        }
    };
    private final Runnable endNow = new Runnable() {
        @Override
        public void run() {
            close();
        }
    };

    /** A Hermes turn: the /delegate stream for one delegation of the voice model. */
    private static final class Delegation {
        final String id;
        final StringBuilder answer = new StringBuilder();
        String failure;
        boolean endCall;
        volatile boolean aborted;
        volatile HttpURLConnection connection;

        Delegation(String id) {
            this.id = id;
        }
    }

    private static final class Approval {
        final String delegationId;
        final String code;

        Approval(String delegationId, String code) {
            this.delegationId = delegationId;
            this.code = code;
        }
    }

    VoiceCall(Context context, Api api, Conversation conversation, Listener listener) {
        this.context = context;
        this.api = api;
        this.conversation = conversation;
        this.listener = listener;
    }

    void start() {
        io.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final long idle = api.get("/config").optLong("idle_seconds", 90) * 1000;
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            idleMs = idle;
                            connect();
                        }
                    });
                } catch (Exception error) {
                    failLater("Settings not loaded: " + error.getMessage());
                }
            }
        });
    }

    private void connect() {
        if (closed) {
            return;
        }
        if (!webrtcLoaded) {
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions
                    .builder(context.getApplicationContext())
                    .createInitializationOptions());
            webrtcLoaded = true;
        }
        audio = JavaAudioDeviceModule.builder(context)
                .setUseHardwareAcousticEchoCanceler(true)
                .setUseHardwareNoiseSuppressor(true)
                .createAudioDeviceModule();
        factory = PeerConnectionFactory.builder()
                .setAudioDeviceModule(audio)
                .createPeerConnectionFactory();
        PeerConnection.RTCConfiguration config =
                new PeerConnection.RTCConfiguration(new ArrayList<PeerConnection.IceServer>());
        config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
        pc = factory.createPeerConnection(config, new PeerObserver());
        if (pc == null) {
            fail("WebRTC refused the connection");
            return;
        }
        source = factory.createAudioSource(new MediaConstraints());
        mic = factory.createAudioTrack("mic", source);
        pc.addTrack(mic, Collections.singletonList("mic"));
        // The data channel must exist before the offer so its m-line is negotiated.
        events = pc.createDataChannel("oai-events", new DataChannel.Init());
        events.registerObserver(new EventsObserver());
        pc.createOffer(new Sdp("offer") {
            @Override
            public void onCreateSuccess(final SessionDescription offer) {
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (closed) {
                            return;
                        }
                        pc.setLocalDescription(new Sdp("local description") {
                            @Override
                            public void onSetSuccess() {
                                main.postDelayed(sendOffer, ICE_TIMEOUT_MS);
                            }
                        }, offer);
                    }
                });
            }
        }, new MediaConstraints());
    }

    private void sendOffer() {
        if (offerSent || closed) {
            return;
        }
        offerSent = true;
        main.removeCallbacks(sendOffer);
        final JSONObject body;
        try {
            body = new JSONObject()
                    .put("sdp", pc.getLocalDescription().description)
                    .put("history", Conversation.toJson(conversation.lines));
        } catch (JSONException error) {
            fail(error.toString());
            return;
        }
        io.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final String answer = api.post("/session", body).getString("sdp");
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            if (closed) {
                                return;
                            }
                            pc.setRemoteDescription(new Sdp("remote description"),
                                    new SessionDescription(SessionDescription.Type.ANSWER, answer));
                            main.postDelayed(tick, TICK_MS);
                        }
                    });
                } catch (Exception error) {
                    failLater(error.getMessage());
                }
            }
        });
    }

    private void tick() {
        if (closed) {
            return;
        }
        long now = SystemClock.elapsedRealtime();
        long quiet = now - lastLoud;
        speaking = quiet < SPEAKING_HOLD_MS;
        if (speaking) {
            lastActivity = now;
        }
        if (ending && endingSpoken && quiet >= END_CALL_QUIET_MS) {
            close();
        } else if (delegation == null && !speaking && now - lastActivity > idleMs) {
            Log.i(CallService.TAG, "hanging up (idle)");
            close();
        }
        main.postDelayed(tick, TICK_MS);
    }

    private boolean send(JSONObject event) {
        if (events == null || events.state() != DataChannel.State.OPEN) {
            return false;
        }
        try {
            eventCounter += 1;
            event.put("event_id", "evt_" + eventCounter);
        } catch (JSONException error) {
            return false;
        }
        byte[] bytes = event.toString().getBytes(StandardCharsets.UTF_8);
        return events.send(new DataChannel.Buffer(ByteBuffer.wrap(bytes), false));
    }

    private void append(String type, String delegationId, String content) {
        try {
            send(new JSONObject()
                    .put("type", type)
                    .put("delegation_id", delegationId)
                    .put("content", truncate(content)));
        } catch (JSONException error) {
            Log.w(CallService.TAG, "append failed", error);
        }
    }

    private void onEvent(JSONObject event) {
        switch (event.optString("type")) {
            case "session.started":
                listener.onListening();
                break;
            case "session.input_transcript.delta":
                lastActivity = SystemClock.elapsedRealtime();
                addTranscript("user", event.optString("delta"));
                break;
            case "session.output_transcript.delta":
                lastActivity = SystemClock.elapsedRealtime();
                addTranscript("assistant", event.optString("delta"));
                if (ending) {
                    endingSpoken = true;
                }
                break;
            case "session.delegation.created":
                JSONObject created = event.optJSONObject("delegation");
                if (created != null) {
                    delegate(created.optString("id"));
                }
                break;
            case "session.usage.updated":
                usageSeconds = usageOf(event, usageSeconds);
                break;
            case "error":
                JSONObject error = event.optJSONObject("error");
                conversation.add("error", error != null
                        ? error.optString("message", "voice model error")
                        : "voice model error");
                break;
            case "session.closed":
                usageSeconds = usageOf(event, usageSeconds);
                finish(event.optString("reason", "closed"), false);
                break;
            default:
                break;
        }
    }

    private static double usageOf(JSONObject event, double fallback) {
        JSONObject usage = event.optJSONObject("usage");
        return usage != null ? usage.optDouble("seconds", fallback) : fallback;
    }

    // Deltas are appended exactly as received; a speaker change starts a new line.
    private void addTranscript(String speaker, String delta) {
        List<Conversation.Line> lines = conversation.lines;
        Conversation.Line last = lines.isEmpty() ? null : lines.get(lines.size() - 1);
        if (last != null && last.speaker.equals(speaker) && speaker.equals(lastSpeaker)) {
            last.text += delta;
            conversation.save();
        } else {
            conversation.add(speaker, delta);
        }
        lastSpeaker = speaker;
    }

    private void delegate(String id) {
        // One Hermes turn at a time: a newer delegation (usually a correction) supersedes the
        // running one, and the server stops the old run. While Hermes waits for an approval,
        // the next delegation is the user's answer, not a new request.
        if (approval != null) {
            answerApproval(id);
            return;
        }
        final boolean replace = delegation != null;
        if (delegation != null) {
            abort(delegation);
        }
        final Delegation current = new Delegation(id);
        delegation = current;
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                runDelegation(current, replace);
            }
        }, DELEGATION_SETTLE_MS);
    }

    private void runDelegation(final Delegation current, boolean replace) {
        // A hang-up meanwhile sent these lines along itself.
        if (delegation != current || closed) {
            return;
        }
        List<Conversation.Line> lines = conversation.undelegated("user", "assistant");
        boolean userSpoke = false;
        for (Conversation.Line line : lines) {
            userSpoke |= line.speaker.equals("user");
        }
        if (!userSpoke) {
            List<Conversation.Line> dialogue = new ArrayList<>();
            for (Conversation.Line line : conversation.lines) {
                if (line.speaker.equals("user") || line.speaker.equals("assistant")) {
                    dialogue.add(line);
                }
            }
            lines = dialogue.subList(Math.max(0, dialogue.size() - 4), dialogue.size());
        }
        conversation.delegated = conversation.lines.size();
        conversation.save();
        final JSONObject body;
        try {
            body = new JSONObject()
                    .put("hermes_session", conversation.hermesSession)
                    .put("lines", Conversation.toJson(lines))
                    .put("replace", replace);
        } catch (JSONException error) {
            return;
        }
        io.execute(new Runnable() {
            @Override
            public void run() {
                stream(current, body);
            }
        });
    }

    /** Network thread: reads /delegate's NDJSON and posts each item to the main thread. */
    private void stream(final Delegation current, JSONObject body) {
        String failure = null;
        HttpURLConnection connection = null;
        try {
            connection = api.stream("/delegate", body);
            current.connection = connection;
            if (current.aborted) {
                return;
            }
            BufferedReader reader = new BufferedReader(
                    new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8));
            for (String line; (line = reader.readLine()) != null; ) {
                // Blank lines are the server's keepalives.
                if (line.trim().isEmpty()) {
                    continue;
                }
                final JSONObject item = new JSONObject(line);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        onItem(current, item);
                    }
                });
            }
        } catch (Exception error) {
            if (current.aborted) {
                return;
            }
            failure = String.valueOf(error.getMessage());
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
        final String streamFailure = failure;
        main.post(new Runnable() {
            @Override
            public void run() {
                onDone(current, streamFailure);
            }
        });
    }

    private void onItem(Delegation current, JSONObject item) {
        if (delegation != current) {
            return;
        }
        lastActivity = SystemClock.elapsedRealtime();
        String type = item.optString("type");
        if (type.equals("approval")) {
            askApproval(current.id, item);
            return;
        }
        // Anything after an approval request means Hermes moved on (answered here, from Matrix,
        // or by its own timeout).
        approval = null;
        if (type.equals("tool") && item.optString("status").equals("running")) {
            append("session.thinking.append", current.id,
                    "Hermes is working on it: " + item.optString("label"));
        } else if (type.equals("end_call")) {
            current.endCall = true;
        } else if (type.equals("delta")) {
            current.answer.append(item.optString("text"));
        } else if (type.equals("done") && item.has("error") && !item.isNull("error")) {
            current.failure = item.optString("error");
        } else if (type.equals("error")) {
            current.failure = item.optString("message");
        }
    }

    private void onDone(Delegation current, String streamFailure) {
        if (delegation != current) {
            return;
        }
        delegation = null;
        approval = null;
        lastActivity = SystemClock.elapsedRealtime();
        String failure = current.failure != null ? current.failure : streamFailure;
        String answer = current.answer.toString().trim();
        if (failure != null && answer.isEmpty()) {
            conversation.add("error", failure);
            append("session.commentary.append", current.id,
                    "The request to Hermes failed: " + failure);
        } else {
            String text = answer.isEmpty() ? "Hermes finished without an answer." : answer;
            conversation.add("hermes", text);
            for (String chunk : chunks(text)) {
                append("session.commentary.append", current.id, chunk);
            }
        }
        if (current.endCall) {
            // Hermes ended the call: close it once the voice has spoken the reply just handed over.
            ending = true;
            endingSpoken = false;
            main.postDelayed(endNow, END_CALL_MAX_MS);
        }
    }

    private void abort(final Delegation current) {
        current.aborted = true;
        io.execute(new Runnable() {
            @Override
            public void run() {
                HttpURLConnection connection = current.connection;
                if (connection != null) {
                    connection.disconnect();
                }
            }
        });
    }

    private void askApproval(String id, JSONObject item) {
        approval = new Approval(id, item.isNull("code") ? null : item.optString("code", null));
        String what = item.optString("description");
        if (what.isEmpty()) {
            what = "run a command";
        }
        String command = item.isNull("command") ? "" : item.optString("command");
        conversation.add("hermes",
                "Approval needed: " + what + (command.isEmpty() ? "" : "\n" + command));
        append("session.commentary.append", id,
                "Hermes needs the user's approval before it continues: " + what + "."
                        + (command.isEmpty() ? "" : " The command is: " + command + ".")
                        + " Ask the user whether to approve or deny it.");
    }

    private void answerApproval(final String id) {
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (closed) {
                    return;
                }
                StringBuilder said = new StringBuilder();
                for (Conversation.Line line : conversation.undelegated("user")) {
                    said.append(line.text).append(' ');
                }
                conversation.delegated = conversation.lines.size();
                conversation.save();
                String choice = classifyApproval(said.toString());
                if (choice == null) {
                    append("session.commentary.append", id,
                            "That was not a clear answer. Ask the user again: approve or deny?");
                    return;
                }
                respondApproval(choice, id);
            }
        }, DELEGATION_SETTLE_MS);
    }

    static String classifyApproval(String said) {
        if (DENY.matcher(said).find()) {
            return "deny";
        }
        if (APPROVE.matcher(said).find()) {
            return "once";
        }
        return null;
    }

    private void respondApproval(final String choice, final String replyId) {
        final Approval answered = approval;
        if (answered == null) {
            return;
        }
        approval = null;
        io.execute(new Runnable() {
            @Override
            public void run() {
                String message;
                boolean ok = false;
                try {
                    api.post("/approve", new JSONObject()
                            .put("code", answered.code == null ? JSONObject.NULL : answered.code)
                            .put("choice", choice));
                    ok = true;
                    message = choice.equals("deny")
                            ? "Denied. Hermes will not run it."
                            : "Approved. Hermes is continuing.";
                } catch (Exception error) {
                    message = "Could not send the answer to Hermes: " + error.getMessage();
                }
                final String reply = message;
                final boolean sent = ok;
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        conversation.add(sent ? "hermes" : "error", reply);
                        // A fast turn can finish before this reply returns; its result was already
                        // handed to the voice, so an "is continuing" would be stale.
                        if (closed || (sent && delegation == null)) {
                            return;
                        }
                        append("session.commentary.append",
                                replyId != null ? replyId : answered.delegationId, reply);
                    }
                });
            }
        });
    }

    /** Ends the call gracefully: the voice model closes the session and reports final usage. */
    void close() {
        if (closed || closing) {
            return;
        }
        closing = true;
        try {
            if (!send(new JSONObject().put("type", "session.close"))) {
                finish("closed", false);
                return;
            }
        } catch (JSONException error) {
            finish("closed", false);
            return;
        }
        main.postDelayed(closeTimedOut, CLOSE_TIMEOUT_MS);
    }

    private void failLater(final String message) {
        main.post(new Runnable() {
            @Override
            public void run() {
                fail(message);
            }
        });
    }

    private void fail(String message) {
        if (closed) {
            return;
        }
        Log.w(CallService.TAG, "call failed: " + message);
        conversation.add("error", String.valueOf(message));
        finish("failed to start", true);
    }

    private void finish(String reason, boolean failed) {
        if (closed) {
            return;
        }
        closed = true;
        main.removeCallbacksAndMessages(null);
        hangUp();
        // Only the stream is dropped; the server keeps following the Hermes run.
        if (delegation != null) {
            abort(delegation);
            delegation = null;
        }
        if (events != null) {
            events.unregisterObserver();
            events.close();
            events.dispose();
        }
        if (pc != null) {
            pc.close();
            pc.dispose();
        }
        if (mic != null) {
            mic.dispose();
        }
        if (source != null) {
            source.dispose();
        }
        if (factory != null) {
            factory.dispose();
        }
        if (audio != null) {
            audio.release();
        }
        conversation.billedSeconds += usageSeconds;
        conversation.save();
        io.shutdown();
        Log.i(CallService.TAG, "call ended: " + reason);
        listener.onFinished(reason, failed);
    }

    // Tell the server the call is over, with what the user said since the last delegation: a
    // request spoken right before hanging up still reaches Hermes.
    private void hangUp() {
        List<Conversation.Line> lines = conversation.undelegated("user", "assistant");
        conversation.delegated = conversation.lines.size();
        conversation.save();
        final JSONObject body;
        try {
            body = new JSONObject()
                    .put("hermes_session", conversation.hermesSession)
                    .put("lines", Conversation.toJson(lines));
        } catch (JSONException error) {
            return;
        }
        io.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    api.post("/hangup", body);
                } catch (Exception error) {
                    Log.w(CallService.TAG, "hang-up not delivered: " + error.getMessage());
                }
            }
        });
    }

    private static String truncate(String text) {
        return text.length() > APPEND_CHAR_LIMIT ? text.substring(0, APPEND_CHAR_LIMIT) : text;
    }

    /** Sentences packed into appends of at most APPEND_CHAR_LIMIT characters. */
    static List<String> chunks(String text) {
        String clean = text.replaceAll("\\s+", " ").trim();
        List<String> out = new ArrayList<>();
        String current = "";
        for (String sentence : clean.split("(?<=[.!?])\\s+")) {
            if (sentence.length() > APPEND_CHAR_LIMIT) {
                if (!current.isEmpty()) {
                    out.add(current);
                }
                current = "";
                for (int i = 0; i < sentence.length(); i += APPEND_CHAR_LIMIT) {
                    out.add(sentence.substring(i, Math.min(sentence.length(), i + APPEND_CHAR_LIMIT)));
                }
            } else if (!current.isEmpty()
                    && current.length() + 1 + sentence.length() > APPEND_CHAR_LIMIT) {
                out.add(current);
                current = sentence;
            } else {
                current = current.isEmpty() ? sentence : current + " " + sentence;
            }
        }
        if (!current.isEmpty()) {
            out.add(current);
        }
        return out;
    }

    /** Logs failures; a failed description ends the call. */
    private class Sdp implements SdpObserver {
        private final String what;

        Sdp(String what) {
            this.what = what;
        }

        @Override
        public void onCreateSuccess(SessionDescription description) {}

        @Override
        public void onSetSuccess() {}

        @Override
        public void onCreateFailure(String error) {
            failLater(what + ": " + error);
        }

        @Override
        public void onSetFailure(String error) {
            failLater(what + ": " + error);
        }
    }

    private class PeerObserver implements PeerConnection.Observer {
        @Override
        public void onConnectionChange(PeerConnection.PeerConnectionState state) {
            if (state == PeerConnection.PeerConnectionState.FAILED
                    || state == PeerConnection.PeerConnectionState.DISCONNECTED) {
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        finish("connection lost", false);
                    }
                });
            }
        }

        @Override
        public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
            if (state == PeerConnection.IceGatheringState.COMPLETE) {
                main.post(sendOffer);
            }
        }

        // The voice's audio plays by itself; the sink only measures it, for speaking().
        @Override
        public void onAddTrack(RtpReceiver receiver, MediaStream[] streams) {
            MediaStreamTrack track = receiver.track();
            if (track instanceof AudioTrack) {
                ((AudioTrack) track).addSink(new AudioTrackSink() {
                    @Override
                    public void onData(ByteBuffer data, int bitsPerSample, int sampleRate,
                            int channels, int frames, long timestamp) {
                        if (bitsPerSample != 16) {
                            return;
                        }
                        ShortBuffer samples = data.duplicate().order(ByteOrder.nativeOrder())
                                .asShortBuffer();
                        while (samples.hasRemaining()) {
                            if (Math.abs(samples.get()) > SPEAKING_PEAK) {
                                lastLoud = SystemClock.elapsedRealtime();
                                return;
                            }
                        }
                    }
                });
            }
        }

        @Override
        public void onSignalingChange(PeerConnection.SignalingState state) {}

        @Override
        public void onIceConnectionChange(PeerConnection.IceConnectionState state) {}

        @Override
        public void onIceConnectionReceivingChange(boolean receiving) {}

        @Override
        public void onIceCandidate(IceCandidate candidate) {}

        @Override
        public void onIceCandidatesRemoved(IceCandidate[] candidates) {}

        @Override
        public void onAddStream(MediaStream stream) {}

        @Override
        public void onRemoveStream(MediaStream stream) {}

        @Override
        public void onDataChannel(DataChannel channel) {}

        @Override
        public void onRenegotiationNeeded() {}
    }

    private class EventsObserver implements DataChannel.Observer {
        @Override
        public void onMessage(DataChannel.Buffer buffer) {
            byte[] bytes = new byte[buffer.data.remaining()];
            buffer.data.get(bytes);
            final String text = new String(bytes, StandardCharsets.UTF_8);
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (closed) {
                        return;
                    }
                    try {
                        onEvent(new JSONObject(text));
                    } catch (JSONException error) {
                        Log.w(CallService.TAG, "unreadable event", error);
                    }
                }
            });
        }

        @Override
        public void onStateChange() {
            if (events.state() == DataChannel.State.CLOSED) {
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        finish("connection closed", false);
                    }
                });
            }
        }

        @Override
        public void onBufferedAmountChange(long previous) {}
    }
}
