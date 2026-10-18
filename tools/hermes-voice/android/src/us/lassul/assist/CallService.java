package us.lassul.assist;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Person;
import android.app.Service;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.media.AudioManager;
import android.media.ToneGenerator;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.OutcomeReceiver;
import android.telecom.CallAttributes;
import android.telecom.CallControl;
import android.telecom.CallControlCallback;
import android.telecom.CallEndpoint;
import android.telecom.CallEventCallback;
import android.telecom.CallException;
import android.telecom.DisconnectCause;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.util.Log;
import java.util.List;
import java.util.function.Consumer;

/**
 * One call at a time, without a screen: a VoiceCall held as a self-managed Telecom call, so the
 * audio goes to the Bluetooth headset and its hang-up button (AT+CHUP) ends the call. In the
 * foreground with the microphone; stops when the call ends. A tone says the voice listens (or
 * that the call failed).
 */
public class CallService extends Service {
    static final String TAG = "Assist";
    static final String ACTION_START = "us.lassul.assist.START";
    static final String ACTION_HANG_UP = "us.lassul.assist.HANG_UP";
    private static final String CHANNEL = "call";
    private static final int NOTIFICATION = 1;

    private final Handler main = new Handler(Looper.getMainLooper());
    private PhoneAccountHandle account;
    private CallControl telecom;
    private VoiceCall voice;
    // What the main screen shows (main thread); null without a call.
    private static String state;

    static String state() {
        return state;
    }

    private static void setState(String next) {
        state = next;
        Live.changed();
    }

    @Override
    public void onCreate() {
        super.onCreate();
        getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL, "Voice call", NotificationManager.IMPORTANCE_LOW));
        account = new PhoneAccountHandle(new ComponentName(this, CallService.class), "assist");
        getSystemService(TelecomManager.class).registerPhoneAccount(
                PhoneAccount.builder(account, "Assist")
                        .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED
                                | PhoneAccount.CAPABILITY_SUPPORTS_TRANSACTIONAL_OPERATIONS)
                        .setSupportedUriSchemes(List.of(PhoneAccount.SCHEME_SIP))
                        .build());
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_HANG_UP.equals(action)) {
            if (voice != null) {
                voice.close();
            } else {
                stopSelf();
            }
            return START_NOT_STICKY;
        }
        if (voice != null) {
            // A call runs already: the button press changes nothing.
            return START_NOT_STICKY;
        }
        Api api = Api.load(this);
        if (api == null
                || checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                        != PackageManager.PERMISSION_GRANTED) {
            // startForegroundService() needs startForeground(); the microphone type would be
            // refused without the permission.
            startForeground(NOTIFICATION, setupNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL);
            Log.w(TAG, "not set up: open Assist");
            tone(ToneGenerator.TONE_PROP_NACK);
            main.postDelayed(new Runnable() {
                @Override
                public void run() {
                    stopSelf();
                }
            }, 1000);
            return START_NOT_STICKY;
        }
        startForeground(NOTIFICATION, callNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                        | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        setState("Connecting…");
        voice = new VoiceCall(this, api, Conversation.load(this), new VoiceCall.Listener() {
            @Override
            public void onListening() {
                setState("Listening");
                tone(ToneGenerator.TONE_PROP_ACK);
            }

            @Override
            public void onFinished(String reason, boolean failed) {
                voice = null;
                setState(null);
                if (failed) {
                    tone(ToneGenerator.TONE_PROP_NACK);
                }
                disconnectTelecom();
                // Let a failure tone play before the service, and with it the call audio, goes.
                main.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        if (voice == null) {
                            stopSelf();
                        }
                    }
                }, failed ? 1000 : 0);
            }
        });
        addTelecomCall();
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        main.removeCallbacksAndMessages(null);
        if (voice != null) {
            voice.close();
        }
        disconnectTelecom();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /** The voice starts once Telecom has the call (audio routed), or without it if refused. */
    private void addTelecomCall() {
        CallAttributes attributes = new CallAttributes.Builder(
                        account,
                        CallAttributes.DIRECTION_OUTGOING,
                        "Hermes",
                        Uri.fromParts(PhoneAccount.SCHEME_SIP, "hermes@assist.lassul.us", null))
                .setCallType(CallAttributes.AUDIO_CALL)
                .build();
        getSystemService(TelecomManager.class).addCall(
                attributes,
                getMainExecutor(),
                new OutcomeReceiver<CallControl, CallException>() {
                    @Override
                    public void onResult(CallControl control) {
                        if (voice == null) {
                            control.disconnect(new DisconnectCause(DisconnectCause.LOCAL),
                                    getMainExecutor(), logged("disconnect"));
                            return;
                        }
                        telecom = control;
                        control.setActive(getMainExecutor(), logged("setActive"));
                        voice.start();
                    }

                    @Override
                    public void onError(CallException error) {
                        Log.w(TAG, "telecom refused the call; the headset cannot hang up", error);
                        if (voice != null) {
                            voice.start();
                        }
                    }
                },
                new Control(),
                new Events());
    }

    private void disconnectTelecom() {
        if (telecom != null) {
            telecom.disconnect(new DisconnectCause(DisconnectCause.LOCAL), getMainExecutor(),
                    logged("disconnect"));
            telecom = null;
        }
    }

    private void tone(int tone) {
        final ToneGenerator generator = new ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80);
        generator.startTone(tone, 300);
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                generator.release();
            }
        }, 500);
    }

    private Notification callNotification() {
        PendingIntent hangUp = PendingIntent.getService(this, 0,
                new Intent(this, CallService.class).setAction(ACTION_HANG_UP),
                PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setStyle(Notification.CallStyle.forOngoingCall(
                        new Person.Builder().setName("Hermes").build(), hangUp))
                .setOngoing(true)
                .build();
    }

    private Notification setupNotification() {
        PendingIntent setup = PendingIntent.getActivity(this, 0,
                new Intent(this, SettingsActivity.class), PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle("Assist is not set up")
                .setContentText("Open it to enter the token and allow the microphone")
                .setContentIntent(setup)
                .build();
    }

    private static OutcomeReceiver<Void, CallException> logged(final String what) {
        return new OutcomeReceiver<Void, CallException>() {
            @Override
            public void onResult(Void result) {}

            @Override
            public void onError(CallException error) {
                Log.w(TAG, what + " failed", error);
            }
        };
    }

    private final class Control implements CallControlCallback {
        @Override
        public void onSetActive(Consumer<Boolean> done) {
            done.accept(true);
        }

        @Override
        public void onSetInactive(Consumer<Boolean> done) {
            done.accept(true);
        }

        @Override
        public void onAnswer(int videoState, Consumer<Boolean> done) {
            done.accept(true);
        }

        // Telecom ended the call: the headset hung up (AT+CHUP) or another call took over.
        @Override
        public void onDisconnect(DisconnectCause cause, Consumer<Boolean> done) {
            Log.i(TAG, "telecom disconnect: " + cause);
            done.accept(true);
            telecom = null;
            if (voice != null) {
                voice.close();
            }
        }

        @Override
        public void onCallStreamingStarted(Consumer<Boolean> done) {
            done.accept(false);
        }
    }

    private static final class Events implements CallEventCallback {
        @Override
        public void onCallEndpointChanged(CallEndpoint endpoint) {
            Log.i(TAG, "audio to " + endpoint);
        }

        @Override
        public void onAvailableCallEndpointsChanged(List<CallEndpoint> endpoints) {}

        @Override
        public void onMuteStateChanged(boolean muted) {}

        @Override
        public void onCallStreamingFailed(int reason) {}

        @Override
        public void onEvent(String event, Bundle extras) {}
    }
}
