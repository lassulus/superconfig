package us.lassul.assist;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * Setup: the app token (`clan vars get coaxmetal hermes-voice-app/token`), the microphone and
 * notification permissions and the TV URL.
 */
public class SettingsActivity extends Activity {
    private TextView status;
    private EditText token;
    private EditText tvUrl;
    private Button permissions;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getActionBar().setDisplayHomeAsUpEnabled(true);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);

        status = new TextView(this);
        status.setPadding(0, 0, 0, pad);
        layout.addView(status);

        token = new EditText(this);
        token.setHint("App token");
        token.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        // A password manager's popup over the field swallows the tap on Save.
        token.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        layout.addView(token);
        layout.addView(button("Save token", new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                if (token.getText().toString().trim().isEmpty()) {
                    return;
                }
                Api.saveToken(SettingsActivity.this, token.getText().toString());
                token.setText("");
                refresh();
            }
        }));

        permissions = button("Allow microphone and notifications", new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                requestPermissions(new String[] {
                    Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS
                }, 0);
            }
        });
        layout.addView(permissions);

        tvUrl = new EditText(this);
        tvUrl.setHint("TV URL");
        tvUrl.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        tvUrl.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        tvUrl.setText(Tv.url(this));
        layout.addView(tvUrl);
        layout.addView(button("Save TV URL", new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                String url = Tv.parse(tvUrl.getText().toString(), false);
                if (url == null) {
                    Toast.makeText(SettingsActivity.this, "Not a URL", Toast.LENGTH_SHORT).show();
                    return;
                }
                Tv.saveUrl(SettingsActivity.this, url);
                tvUrl.setText(url);
                refresh();
            }
        }));

        TextView help = new TextView(this);
        help.setPadding(0, pad, 0, 0);
        help.setTextColor(Conversation.DIM);
        help.setText("The token: clan vars get coaxmetal hermes-voice-app/token\n\n"
                + "Hold the headset's voice button to talk to Hermes, a short press hangs up;"
                + " a tone says it listens. Pick Assist when Android asks which app handles voice"
                + " commands. On GrapheneOS, Assist also needs the Network permission.\n\n"
                + "The TV URL is the TV page with its secret path, https://tv.lassul.us/…/;"
                + " sharing a tv.lassul.us link with Assist sets it too.");
        layout.addView(help);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(layout);
        Ui.fitBars(this, scroll, pad);
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        refresh();
    }

    @Override
    public boolean onNavigateUp() {
        finish();
        return true;
    }

    private void refresh() {
        boolean mic = checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
        status.setText("Token: " + (Api.hasToken(this) ? "set" : "missing")
                + "\nMicrophone: " + (mic ? "allowed" : "not allowed")
                + "\nTV URL: " + (Tv.url(this) != null ? "set" : "missing"));
        permissions.setVisibility(mic ? View.GONE : View.VISIBLE);
    }

    private Button button(String label, View.OnClickListener action) {
        Button button = new Button(this);
        button.setText(label);
        button.setOnClickListener(action);
        return button;
    }
}
