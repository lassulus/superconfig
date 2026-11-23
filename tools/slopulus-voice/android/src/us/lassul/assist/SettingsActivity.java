package us.lassul.assist;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import org.json.JSONObject;

/**
 * Setup: the app token (`clan vars get coaxmetal hermes-voice-app/token`), the microphone and
 * notification permissions, the TV URL and the call's voice.
 */
public class SettingsActivity extends Activity {
    private TextView status;
    private EditText token;
    private EditText tvUrl;
    private Button permissions;
    private TextView voiceLabel;
    private Spinner voice;
    /** The server's voice names, in the spinner's order. */
    private final List<String> voiceNames = new ArrayList<>();
    private int voiceShown;

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
                loadVoices();
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

        voiceLabel = new TextView(this);
        voiceLabel.setPadding(0, pad, 0, 0);
        voiceLabel.setTextColor(Conversation.DIM);
        voiceLabel.setText("Voice");
        voiceLabel.setVisibility(View.GONE);
        layout.addView(voiceLabel);
        voice = new Spinner(this);
        voice.setVisibility(View.GONE);
        voice.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                // Spinner also reports the initial selection; only a change is saved.
                if (position != voiceShown) {
                    voiceShown = position;
                    Api.saveVoice(SettingsActivity.this, voiceNames.get(position));
                }
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {}
        });
        layout.addView(voice);

        TextView help = new TextView(this);
        help.setPadding(0, pad, 0, 0);
        help.setTextColor(Conversation.DIM);
        help.setText("The token: clan vars get coaxmetal hermes-voice-app/token\n\n"
                + "Hold the headset's voice button to talk to slopulus, a short press hangs up;"
                + " a tone says it listens. Pick Assist when Android asks which app handles voice"
                + " commands. On GrapheneOS, Assist also needs the Network permission.\n\n"
                + "The TV URL is the TV page with its secret path, https://glotz.lassul.us/…/;"
                + " sharing a glotz.lassul.us link with Assist sets it too.");
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
        loadVoices();
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

    /** Fills the voice spinner from /config's voices; needs the token. */
    private void loadVoices() {
        final Api api = Api.load(this);
        if (api == null) {
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    final JSONObject config = api.get("/config");
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (!isDestroyed()) {
                                showVoices(config);
                            }
                        }
                    });
                } catch (final Exception error) {
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            Toast.makeText(SettingsActivity.this,
                                    "Voices not loaded: " + error.getMessage(),
                                    Toast.LENGTH_SHORT).show();
                        }
                    });
                }
            }
        }).start();
    }

    /** Shows the saved voice, or the server's default if none is saved or it is gone. */
    private void showVoices(JSONObject config) {
        JSONObject voices = config.optJSONObject("voices");
        if (voices == null) {
            return;
        }
        String saved = Api.voice(this);
        String shown = saved != null && voices.has(saved) ? saved : config.optString("voice");
        voiceNames.clear();
        voiceShown = 0;
        List<String> labels = new ArrayList<>();
        for (Iterator<String> names = voices.keys(); names.hasNext(); ) {
            String name = names.next();
            if (name.equals(shown)) {
                voiceShown = voiceNames.size();
            }
            voiceNames.add(name);
            labels.add(name + " — " + voices.optString(name));
        }
        ArrayAdapter<String> adapter =
                new ArrayAdapter<>(this, android.R.layout.simple_spinner_item, labels);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        voice.setAdapter(adapter);
        voice.setSelection(voiceShown);
        voiceLabel.setVisibility(View.VISIBLE);
        voice.setVisibility(View.VISIBLE);
    }
}
