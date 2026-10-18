package us.lassul.assist;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.util.AtomicFile;
import android.util.Log;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * A conversation with Hermes across calls, like the web page's localStorage state: the
 * transcript, how much of it went to Hermes already, and Hermes's session id. Every conversation
 * is a file in conversations/; the current one continues with the next call unless the last call
 * is over an hour old or "New conversation" was chosen.
 */
final class Conversation {
    static final int ACCENT = Color.parseColor("#4fb477");
    static final int LIVE = Color.parseColor("#d9534f");
    static final int DIM = Color.parseColor("#8a8a8a");
    private static final long NEW_AFTER_MS = 60 * 60 * 1000;
    private static final String PREFS = "conversation";

    static final class Line {
        final String speaker;
        String text;

        Line(String speaker, String text) {
            this.speaker = speaker;
            this.text = text;
        }
    }

    final String hermesSession;
    final long started;
    final List<Line> lines = new ArrayList<>();
    // Lines before this index went to Hermes (delegation or hang-up) already.
    int delegated;
    double billedSeconds;
    private final Context context;

    private Conversation(Context context, String hermesSession, long started) {
        this.context = context.getApplicationContext();
        this.hermesSession = hermesSession;
        this.started = started;
    }

    /** The conversation the next call continues. */
    static Conversation load(Context context) {
        SharedPreferences prefs = prefs(context);
        String current = prefs.getString("current", null);
        if (current != null
                && System.currentTimeMillis() - prefs.getLong("last_used", 0) < NEW_AFTER_MS) {
            Conversation saved = read(context, current);
            if (saved != null) {
                return saved;
            }
        }
        return new Conversation(context, newSessionId(), System.currentTimeMillis());
    }

    /** The conversation shown on the main screen: the current one, however old; null if none. */
    static Conversation current(Context context) {
        String current = prefs(context).getString("current", null);
        return current == null ? null : read(context, current);
    }

    /** The next call starts a new conversation (and Hermes session); the old one stays listed. */
    static void startNew(Context context) {
        prefs(context).edit().remove("current").apply();
        Live.changed();
    }

    /** All conversations, newest first. */
    static List<Conversation> all(Context context) {
        File[] files = directory(context).listFiles();
        List<Conversation> out = new ArrayList<>();
        for (File file : files == null ? new File[0] : files) {
            String name = file.getName();
            if (name.endsWith(".json")) {
                Conversation conversation =
                        read(context, name.substring(0, name.length() - ".json".length()));
                if (conversation != null) {
                    out.add(conversation);
                }
            }
        }
        Collections.sort(out, new Comparator<Conversation>() {
            @Override
            public int compare(Conversation a, Conversation b) {
                return Long.compare(b.started, a.started);
            }
        });
        return out;
    }

    static Conversation read(Context context, String hermesSession) {
        File file = file(context, hermesSession);
        if (!file.exists()) {
            return null;
        }
        try {
            JSONObject state = new JSONObject(
                    new String(new AtomicFile(file).readFully(), StandardCharsets.UTF_8));
            Conversation conversation = new Conversation(context, hermesSession,
                    state.optLong("started", file.lastModified()));
            JSONArray lines = state.getJSONArray("lines");
            for (int i = 0; i < lines.length(); i++) {
                JSONObject line = lines.getJSONObject(i);
                conversation.lines.add(new Line(line.getString("speaker"), line.getString("text")));
            }
            conversation.delegated = state.optInt("delegated", conversation.lines.size());
            conversation.billedSeconds = state.optDouble("billed_seconds", 0);
            return conversation;
        } catch (IOException | JSONException error) {
            Log.w(CallService.TAG, "unreadable conversation " + hermesSession, error);
            return null;
        }
    }

    /** voice-YYYYMMDD-<hex>, like the web page's. */
    private static String newSessionId() {
        SimpleDateFormat day = new SimpleDateFormat("yyyyMMdd", Locale.ROOT);
        day.setTimeZone(TimeZone.getTimeZone("UTC"));
        String random = Integer.toHexString(new SecureRandom().nextInt());
        return "voice-" + day.format(new Date()) + "-" + random;
    }

    void save() {
        AtomicFile file = new AtomicFile(file(context, hermesSession));
        FileOutputStream out = null;
        try {
            JSONObject state = new JSONObject()
                    .put("started", started)
                    .put("lines", toJson(lines))
                    .put("delegated", delegated)
                    .put("billed_seconds", billedSeconds);
            directory(context).mkdirs();
            out = file.startWrite();
            out.write(state.toString().getBytes(StandardCharsets.UTF_8));
            file.finishWrite(out);
        } catch (IOException | JSONException error) {
            file.failWrite(out);
            Log.w(CallService.TAG, "conversation not saved", error);
            return;
        }
        prefs(context).edit()
                .putString("current", hermesSession)
                .putLong("last_used", System.currentTimeMillis())
                .apply();
        Live.changed();
    }

    void add(String speaker, String text) {
        lines.add(new Line(speaker, text));
        save();
    }

    /** Lines since the last hand-over to Hermes, of the given speakers. */
    List<Line> undelegated(String... speakers) {
        List<Line> out = new ArrayList<>();
        List<String> wanted = Arrays.asList(speakers);
        for (Line line : lines.subList(Math.min(delegated, lines.size()), lines.size())) {
            if (wanted.contains(line.speaker)) {
                out.add(line);
            }
        }
        return out;
    }

    /** The first thing the user said, for the session list. */
    String title() {
        for (Line line : lines) {
            if (line.speaker.equals("user") && !line.text.trim().isEmpty()) {
                return line.text.trim();
            }
        }
        return "(nothing said)";
    }

    /** The transcript as the web page shows it: colored speaker labels, Hermes dimmed. */
    CharSequence render() {
        SpannableStringBuilder out = new SpannableStringBuilder();
        for (Line line : lines) {
            String text = line.text.trim();
            if (text.isEmpty()) {
                continue;
            }
            if (out.length() > 0) {
                out.append("\n\n");
            }
            String label;
            int labelColor;
            int textColor = 0;
            switch (line.speaker) {
                case "user":
                    label = "you: ";
                    labelColor = ACCENT;
                    break;
                case "assistant":
                    label = "voice: ";
                    labelColor = DIM;
                    break;
                case "error":
                    label = "error: ";
                    labelColor = LIVE;
                    textColor = LIVE;
                    break;
                default:
                    label = line.speaker + ": ";
                    labelColor = ACCENT;
                    textColor = DIM;
                    break;
            }
            int start = out.length();
            out.append(label);
            out.setSpan(new ForegroundColorSpan(labelColor), start, out.length(),
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            out.setSpan(new StyleSpan(Typeface.BOLD), start, out.length(),
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            int body = out.length();
            out.append(text);
            if (textColor != 0) {
                out.setSpan(new ForegroundColorSpan(textColor), body, out.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        }
        return out;
    }

    static JSONArray toJson(List<Line> lines) throws JSONException {
        JSONArray out = new JSONArray();
        for (Line line : lines) {
            out.put(new JSONObject().put("speaker", line.speaker).put("text", line.text));
        }
        return out;
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static File directory(Context context) {
        return new File(context.getFilesDir(), "conversations");
    }

    private static File file(Context context, String hermesSession) {
        return new File(directory(context), hermesSession + ".json");
    }
}
