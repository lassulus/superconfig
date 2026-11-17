package us.lassul.assist;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.drawable.Icon;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.IBinder;
import android.os.PowerManager;

/**
 * The TV in the foreground while it is on, with the screen or without (audio only, the display
 * off): its media notification and session (play/pause, show video, stop, the headset's media
 * buttons), and a wake and a Wi-Fi lock while it plays.
 */
public class TvService extends Service {
    static final String ACTION_AUDIO = "us.lassul.assist.TV_AUDIO";
    static final String ACTION_PLAY = "us.lassul.assist.TV_PLAY";
    static final String ACTION_PAUSE = "us.lassul.assist.TV_PAUSE";
    static final String ACTION_STOP = "us.lassul.assist.TV_STOP";
    // Ends the call and goes on with the TV (audio only unless its screen is open).
    static final String ACTION_FROM_CALL = "us.lassul.assist.TV_FROM_CALL";
    private static final String CHANNEL = "tv";
    private static final int NOTIFICATION = 2;

    private MediaSession session;
    private PowerManager.WakeLock wake;
    private WifiManager.WifiLock wifi;
    // What the notification and the session show; skips redraws for unrelated changes.
    private String shown;
    private final Runnable redraw = new Runnable() {
        @Override
        public void run() {
            refresh();
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL, "TV", NotificationManager.IMPORTANCE_LOW));
        session = new MediaSession(this, "tv");
        session.setCallback(new Controls());
        session.setSessionActivity(showVideo());
        session.setActive(true);
        wake = getSystemService(PowerManager.class)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "assist:tv");
        wake.setReferenceCounted(false);
        // HIGH_PERF is what media players still ask for to stream with the display off.
        @SuppressWarnings("deprecation")
        int mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF;
        wifi = getApplicationContext().getSystemService(WifiManager.class)
                .createWifiLock(mode, "assist:tv");
        wifi.setReferenceCounted(false);
        Live.watch(redraw);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION, notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        String action = intent != null ? intent.getAction() : null;
        boolean control = ACTION_PLAY.equals(action) || ACTION_PAUSE.equals(action);
        // Controls of a notification that outlived its TV end it.
        if (ACTION_STOP.equals(action) || (control && !Tv.on()) || !Tv.start(this)) {
            Tv.stop(this);
            return START_NOT_STICKY;
        }
        if (ACTION_PLAY.equals(action)) {
            Tv.setPaused(false);
        } else if (ACTION_PAUSE.equals(action)) {
            Tv.setPaused(true);
        } else if (ACTION_AUDIO.equals(action)) {
            Tv.audioOnly();
        } else if (ACTION_FROM_CALL.equals(action) && CallService.state() != null) {
            // The TV stays silent until the call has ended (Tv.muted()).
            startService(new Intent(this, CallService.class).setAction(CallService.ACTION_HANG_UP));
        }
        refresh();
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        Live.unwatch(redraw);
        session.release();
        wake.release();
        wifi.release();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /** Starts the TV without the screen (it plays on in the background); needs the foreground. */
    static void startAudio(Context context) {
        context.startForegroundService(new Intent(context, TvService.class).setAction(ACTION_AUDIO));
    }

    /** Hangs up and plays the TV; needs the foreground or a notification's tap. */
    static Intent fromCall(Context context) {
        return new Intent(context, TvService.class).setAction(ACTION_FROM_CALL);
    }

    private void refresh() {
        if (!Tv.on()) {
            return;
        }
        String state = Tv.title() + "\n" + Tv.paused() + " " + Tv.muted() + " " + Tv.showing();
        if (state.equals(shown)) {
            return;
        }
        shown = state;
        // Paused, the page may fall asleep; it seeks back into sync when it plays again.
        if (Tv.paused()) {
            wake.release();
            wifi.release();
        } else {
            wake.acquire();
            wifi.acquire();
        }
        session.setPlaybackState(new PlaybackState.Builder()
                .setState(Tv.muted() ? PlaybackState.STATE_PAUSED : PlaybackState.STATE_PLAYING,
                        PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1)
                .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
                        | PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_STOP)
                // Android 13+ draws the media controls from this, not from the actions below.
                .addCustomAction(new PlaybackState.CustomAction.Builder(
                                ACTION_STOP, "Stop", android.R.drawable.ic_menu_close_clear_cancel)
                        .build())
                .build());
        session.setMetadata(new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title())
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "TV")
                .build());
        getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
    }

    private static String title() {
        return Tv.title().isEmpty() ? "TV" : Tv.title();
    }

    private Notification notification() {
        boolean paused = Tv.paused();
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(title())
                .setContentText(status())
                .setContentIntent(showVideo())
                .setOngoing(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(action(paused ? android.R.drawable.ic_media_play
                                : android.R.drawable.ic_media_pause,
                        paused ? "Play" : "Pause", paused ? ACTION_PLAY : ACTION_PAUSE))
                .addAction(new Notification.Action.Builder(
                                Icon.createWithResource(this, android.R.drawable.ic_menu_slideshow),
                                "Show video", showVideo())
                        .build())
                .addAction(action(android.R.drawable.ic_menu_close_clear_cancel, "Stop", ACTION_STOP))
                .setStyle(new Notification.MediaStyle()
                        .setMediaSession(session.getSessionToken())
                        .setShowActionsInCompactView(0, 1, 2))
                .build();
    }

    private String status() {
        if (Tv.paused()) {
            return "Paused";
        }
        if (CallService.state() != null) {
            return "Silent during the call";
        }
        return Tv.showing() ? "Playing" : "Audio only";
    }

    private Notification.Action action(int icon, String label, String action) {
        return new Notification.Action.Builder(Icon.createWithResource(this, icon), label,
                        control(this, action))
                .build();
    }

    /** One of the TV's controls for a notification or picture-in-picture. */
    static PendingIntent control(Context context, String action) {
        return PendingIntent.getService(context, 0,
                new Intent(context, TvService.class).setAction(action),
                PendingIntent.FLAG_IMMUTABLE);
    }

    private PendingIntent showVideo() {
        return PendingIntent.getActivity(this, 0, new Intent(this, TvActivity.class),
                PendingIntent.FLAG_IMMUTABLE);
    }

    private final class Controls extends MediaSession.Callback {
        @Override
        public void onPlay() {
            Tv.setPaused(false);
        }

        @Override
        public void onPause() {
            Tv.setPaused(true);
        }

        @Override
        public void onStop() {
            Tv.stop(TvService.this);
        }

        @Override
        public void onCustomAction(String action, Bundle extras) {
            if (ACTION_STOP.equals(action)) {
                Tv.stop(TvService.this);
            }
        }
    }
}
