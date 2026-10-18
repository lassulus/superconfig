package us.lassul.assist;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * The launcher screen: the current conversation, live during a call, and a Call / Hang up
 * button. New conversation, the session list and the settings are in the menu.
 */
public class MainActivity extends Activity {
    private static final int NEW_CONVERSATION = 1;
    private static final int SESSIONS = 2;
    private static final int SETTINGS = 3;

    private TextView transcript;
    private ColorStateList textColor;
    private ScrollView scroll;
    private TextView status;
    private Button call;
    private final Runnable redraw = new Runnable() {
        @Override
        public void run() {
            refresh();
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        float dp = getResources().getDisplayMetrics().density;
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        Ui.fitBars(this, layout, Ui.dp(this, 16));

        transcript = new TextView(this);
        transcript.setTextSize(16);
        transcript.setLineSpacing(0, 1.15f);
        transcript.setTextIsSelectable(true);
        textColor = transcript.getTextColors();
        scroll = new ScrollView(this);
        scroll.addView(transcript);
        layout.addView(scroll,
                new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));

        status = new TextView(this);
        status.setGravity(Gravity.CENTER);
        status.setTextColor(Conversation.DIM);
        status.setPadding(0, (int) (12 * dp), 0, (int) (12 * dp));
        layout.addView(status);

        call = new Button(this);
        call.setTextColor(0xffffffff);
        call.setTextSize(20);
        call.setTypeface(Typeface.DEFAULT_BOLD);
        call.setAllCaps(false);
        call.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                if (CallService.state() != null) {
                    startService(new Intent(MainActivity.this, CallService.class)
                            .setAction(CallService.ACTION_HANG_UP));
                } else if (!ready()) {
                    startActivity(new Intent(MainActivity.this, SettingsActivity.class));
                } else {
                    startForegroundService(new Intent(MainActivity.this, CallService.class)
                            .setAction(CallService.ACTION_START));
                }
            }
        });
        layout.addView(call, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, (int) (64 * dp)));
        setContentView(layout);
    }

    @Override
    protected void onResume() {
        super.onResume();
        Live.watch(redraw);
        refresh();
    }

    @Override
    protected void onPause() {
        Live.unwatch(redraw);
        super.onPause();
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(Menu.NONE, NEW_CONVERSATION, 0, "New conversation");
        menu.add(Menu.NONE, SESSIONS, 1, "Sessions");
        menu.add(Menu.NONE, SETTINGS, 2, "Settings");
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        switch (item.getItemId()) {
            case NEW_CONVERSATION:
                if (CallService.state() != null) {
                    // The running call would save its conversation right back.
                    Toast.makeText(this, "Hang up first", Toast.LENGTH_SHORT).show();
                } else {
                    Conversation.startNew(this);
                }
                return true;
            case SESSIONS:
                startActivity(new Intent(this, SessionsActivity.class));
                return true;
            case SETTINGS:
                startActivity(new Intent(this, SettingsActivity.class));
                return true;
            default:
                return super.onOptionsItemSelected(item);
        }
    }

    private boolean ready() {
        return Api.hasToken(this)
                && checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                        == PackageManager.PERMISSION_GRANTED;
    }

    private void refresh() {
        String state = CallService.state();
        boolean ready = ready();
        GradientDrawable background = new GradientDrawable();
        background.setCornerRadius(32 * getResources().getDisplayMetrics().density);
        background.setColor(state != null ? Conversation.LIVE : Conversation.ACCENT);
        call.setBackground(background);
        call.setText(state != null ? "Hang up" : ready ? "Call" : "Set up");
        status.setText(state != null
                ? state
                : ready ? "Hold the headset's voice button, or tap Call" : "Not set up yet");

        Conversation current = Conversation.current(this);
        if (current == null || current.lines.isEmpty()) {
            transcript.setText("New conversation. What you and Hermes say shows up here.");
            transcript.setTextColor(Conversation.DIM);
        } else {
            transcript.setText(current.render());
            transcript.setTextColor(textColor);
        }
        scroll.post(new Runnable() {
            @Override
            public void run() {
                scroll.fullScroll(View.FOCUS_DOWN);
            }
        });
    }
}
