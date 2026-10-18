package us.lassul.assist;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ServiceInfo;
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
 * Holds each call of the page as a self-managed call in Telecom, so a Bluetooth headset sees a
 * call and its hang-up (AT+CHUP) reaches this app, which tells the page. In the foreground, as
 * otherwise Android freezes the process once the page is in front. Stops when idle: a call the
 * page starts after that is not held (the app cannot start this service from the background).
 */
public class CallService extends Service {
    private static final String CHANNEL = "call";
    private static final long IDLE_MS = 2 * 60 * 1000;

    private static CallService running;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable idleStop = new Runnable() {
        @Override
        public void run() {
            stopSelf();
        }
    };
    private PhoneAccountHandle account;
    private CallControl call;
    // The page's call runs; false while adding means: disconnect once added.
    private boolean wanted;

    static void pageStarted() {
        if (running != null) {
            running.startCall();
        }
    }

    static void pageEnded() {
        if (running != null) {
            running.endCall();
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        running = this;
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(
                new NotificationChannel(CHANNEL, "Voice call", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setContentTitle("Assist")
                .setContentText("The headset button hangs up")
                .setOngoing(true)
                .build();
        startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL);
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
        if (call == null && !wanted) {
            idle();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        wanted = false;
        disconnect();
        Link.close();
        running = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void idle() {
        handler.removeCallbacks(idleStop);
        handler.postDelayed(idleStop, IDLE_MS);
    }

    private void startCall() {
        handler.removeCallbacks(idleStop);
        if (wanted) {
            return;
        }
        wanted = true;
        if (call != null) {
            return;
        }
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
                        Log.i(Link.TAG, "telecom call added");
                        call = control;
                        if (wanted) {
                            control.setActive(getMainExecutor(), logged("setActive"));
                        } else {
                            disconnect();
                        }
                    }

                    @Override
                    public void onError(CallException error) {
                        Log.w(Link.TAG, "telecom call refused", error);
                        wanted = false;
                        idle();
                    }
                },
                new Control(),
                new Events());
    }

    private void endCall() {
        wanted = false;
        disconnect();
        idle();
    }

    private void disconnect() {
        if (call != null) {
            call.disconnect(
                    new DisconnectCause(DisconnectCause.LOCAL), getMainExecutor(), logged("disconnect"));
            call = null;
        }
    }

    private static OutcomeReceiver<Void, CallException> logged(String what) {
        return new OutcomeReceiver<Void, CallException>() {
            @Override
            public void onResult(Void result) {}

            @Override
            public void onError(CallException error) {
                Log.w(Link.TAG, what + " failed", error);
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

        // Telecom ended the call: the headset hung up (AT+CHUP) or a call took over.
        @Override
        public void onDisconnect(DisconnectCause cause, Consumer<Boolean> done) {
            Log.i(Link.TAG, "telecom disconnect: " + cause);
            done.accept(true);
            call = null;
            wanted = false;
            Link.hangUp();
            idle();
        }

        @Override
        public void onCallStreamingStarted(Consumer<Boolean> done) {
            done.accept(false);
        }
    }

    private static final class Events implements CallEventCallback {
        @Override
        public void onCallEndpointChanged(CallEndpoint endpoint) {}

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
