<?php

/**
 * Roundcube reads the browser's time zone only from its login form, which
 * OAuth logins never post, so it falls back to the server's UTC. Report the
 * zone from every page instead; that also follows the browser into another
 * zone during a session. A zone set in the user's preferences still wins.
 */
class browser_timezone extends rcube_plugin
{
    public $task = '?(?!login|logout).*';

    public function init()
    {
        $rcmail = rcmail::get_instance();

        $this->register_action('plugin.browser_timezone', [$this, 'save']);

        if ($rcmail->output->type == 'html') {
            $rcmail->output->set_env('browser_timezone', $_SESSION['timezone'] ?? null);
            $this->include_script('browser_timezone.js');
        }
    }

    public function save()
    {
        $rcmail = rcmail::get_instance();
        $timezone = rcube_utils::get_input_string('_timezone', rcube_utils::INPUT_POST);

        try {
            new DateTimeZone($timezone);
            $_SESSION['timezone'] = $timezone;
            $rcmail->output->command('plugin.browser_timezone');
        } catch (Exception $e) {
            rcube::raise_error("browser_timezone: unknown time zone '$timezone'", true);
        }

        $rcmail->output->send();
    }
}
