package us.lassul.assist;

import android.app.Activity;
import android.content.Intent;

/**
 * The headset's voice button (VOICE_COMMAND) and the assist gesture: starts a call and vanishes.
 * Starting it here, in onResume, is what lets CallService run in the foreground with the
 * microphone: Android allows that only while the app is in front, which this activity is for a
 * moment, over the lock screen too (showWhenLocked, turnScreenOn in the manifest).
 */
public class AssistActivity extends Activity {
    @Override
    protected void onResume() {
        super.onResume();
        startForegroundService(new Intent(this, CallService.class).setAction(CallService.ACTION_START));
        finish();
    }
}
