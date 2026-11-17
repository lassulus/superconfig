package us.lassul.assist;

import android.app.Activity;
import android.os.Bundle;
import android.text.format.DateUtils;
import android.widget.ScrollView;
import android.widget.TextView;

/** One conversation's transcript, read-only. */
public class TranscriptActivity extends Activity {
    static final String SESSION = "session";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getActionBar().setDisplayHomeAsUpEnabled(true);
        Conversation conversation = Conversation.read(this, getIntent().getStringExtra(SESSION));
        if (conversation == null) {
            finish();
            return;
        }
        setTitle(DateUtils.formatDateTime(this, conversation.started,
                DateUtils.FORMAT_SHOW_DATE | DateUtils.FORMAT_SHOW_TIME
                        | DateUtils.FORMAT_ABBREV_MONTH));
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        TextView transcript = new TextView(this);
        transcript.setTextSize(16);
        transcript.setLineSpacing(0, 1.15f);
        transcript.setTextIsSelectable(true);
        transcript.setPadding(pad, pad, pad, pad);
        transcript.setText(conversation.render());
        ScrollView scroll = new ScrollView(this);
        scroll.addView(transcript);
        Ui.fitBars(this, scroll, 0);
        setContentView(scroll);
    }

    @Override
    public boolean onNavigateUp() {
        finish();
        return true;
    }
}
