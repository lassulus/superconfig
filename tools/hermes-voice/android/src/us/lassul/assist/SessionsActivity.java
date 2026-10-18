package us.lassul.assist;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.text.format.DateUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.FrameLayout;
import android.widget.ListView;
import android.widget.TextView;
import java.util.List;

/** All conversations, newest first; one opens its transcript. */
public class SessionsActivity extends Activity {
    private ListView list;
    private final Runnable redraw = new Runnable() {
        @Override
        public void run() {
            refresh();
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getActionBar().setDisplayHomeAsUpEnabled(true);
        list = new ListView(this);
        list.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                Conversation conversation = (Conversation) parent.getItemAtPosition(position);
                startActivity(new Intent(SessionsActivity.this, TranscriptActivity.class)
                        .putExtra(TranscriptActivity.SESSION, conversation.hermesSession));
            }
        });
        TextView empty = new TextView(this);
        empty.setText("No conversations yet.");
        empty.setTextColor(Conversation.DIM);
        empty.setGravity(Gravity.CENTER);
        FrameLayout root = new FrameLayout(this);
        root.addView(list);
        root.addView(empty);
        list.setEmptyView(empty);
        Ui.fitBars(this, root, 0);
        setContentView(root);
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
    public boolean onNavigateUp() {
        finish();
        return true;
    }

    private void refresh() {
        List<Conversation> conversations = Conversation.all(this);
        Conversation current = Conversation.current(this);
        final String currentSession = current == null ? null : current.hermesSession;
        list.setAdapter(new ArrayAdapter<Conversation>(
                this, android.R.layout.simple_list_item_2, android.R.id.text1, conversations) {
            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                View row = super.getView(position, convertView, parent);
                Conversation conversation = getItem(position);
                String when = DateUtils.formatDateTime(getContext(), conversation.started,
                        DateUtils.FORMAT_SHOW_DATE | DateUtils.FORMAT_SHOW_TIME
                                | DateUtils.FORMAT_ABBREV_MONTH);
                ((TextView) row.findViewById(android.R.id.text1)).setText(
                        conversation.hermesSession.equals(currentSession)
                                ? when + " · current"
                                : when);
                TextView title = row.findViewById(android.R.id.text2);
                title.setText(conversation.title());
                title.setMaxLines(2);
                return row;
            }
        });
    }
}
