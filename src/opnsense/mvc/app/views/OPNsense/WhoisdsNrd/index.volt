<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<script>
$(function () {
    function showResult(data) {
        $('#nrd-result').removeClass('hidden').text(typeof data === 'string' ? data : JSON.stringify(data, null, 2));
        loadStatus();
    }

    function formatUtc(value) {
        if (!value) return 'Never';
        var d = new Date(value);
        return isNaN(d.getTime()) ? value : d.toLocaleString() + ' (local)';
    }

    function loadStatus() {
        ajaxGet('/api/whoisdsnrd/service/status', {}, function (data) {
            if (data.error) {
                $('#nrd-status').text('Status API error: ' + data.error);
                return;
            }
            $('#nrd-status').text(data.service || 'unknown');
            $('#nrd-http').text(data.http_endpoint ? 'Available (127.0.0.1:18765)' : 'Unavailable');
            $('#nrd-unique').text((data.unique_domains || 0).toLocaleString());
            $('#nrd-raw').text((data.raw_daily_entries || 0).toLocaleString());
            $('#nrd-days').text((data.retained_days || 0) + ' / ' + (data.retention_days || 3));
            $('#nrd-filtered').text((data.excluded_tld_domains || 0).toLocaleString());
            $('#nrd-wildcards').text((data.wildcard_entries || 0).toLocaleString());
            $('#nrd-lines').text((data.published_entries || 0).toLocaleString());
            $('#nrd-tlds').text((data.excluded_tlds || []).join(', ') || '(none)');
            $('#nrd-output').text(data.output_exists ? (data.output_bytes || 0).toLocaleString() + ' bytes' : 'Not generated');
            $('#nrd-last-checked').text(formatUtc(data.last_checked_utc));
            $('#nrd-last-success').text(formatUtc(data.last_successful_update_utc));
            $('#nrd-last-rebuild').text(formatUtc(data.last_feed_rebuild_utc));
            $('#nrd-unbound-state').text(data.unbound_ingest_status || 'unknown');
            $('#nrd-last-unbound').text(formatUtc(data.last_unbound_ingest_utc));
            $('#nrd-unbound-error').text(data.unbound_ingest_error || '');
            $('#nrd-anchor').text(data.anchor_date || 'Not established');
            if (!data.stats_available) {
                $('#nrd-stats-note').removeClass('hidden').text('Feed statistics will populate after the next successful Update Now run.');
            } else {
                $('#nrd-stats-note').addClass('hidden').text('');
            }
            if (data.settings_error) {
                $('#nrd-settings-error').removeClass('hidden').text('Settings error: ' + data.settings_error);
            } else {
                $('#nrd-settings-error').addClass('hidden').text('');
            }
            var rows = '';
            (data.days || []).forEach(function (d) {
                rows += '<tr><td>' + $('<div>').text(d.date).html() + '</td><td>' + Number(d.domains).toLocaleString() + '</td><td>' + Number(d.size_bytes).toLocaleString() + ' bytes</td></tr>';
            });
            $('#nrd-days-table tbody').html(rows || '<tr><td colspan="3">No daily archives found</td></tr>');
        });
    }

    function action(endpoint, label) {
        $('#nrd-result').addClass('hidden');
        ajaxCall(endpoint, {}, function (data) { showResult(data); }, function () { showResult(label + ' request failed'); });
    }

    $('#nrd-save-settings').click(function () {
        $('#nrd-settings-result').removeClass('hidden').text('Saving settings…');
        saveFormToEndpoint('/api/whoisdsnrd/settings/set', 'frm_NRDSettings', function () {
            ajaxCall('/api/whoisdsnrd/service/reload', {}, function (reloadData) {
                if (!reloadData || reloadData.status !== 'ok') {
                    $('#nrd-settings-result').text('Settings were saved, but the generated settings file could not be refreshed: ' + JSON.stringify(reloadData));
                    return;
                }
                ajaxCall('/api/whoisdsnrd/service/rebuild', {}, function (rebuildData) {
                    $('#nrd-settings-result').text(
                        'Settings saved. The aggregate and Unbound refresh were updated only if the archive set or settings changed.\n\n' +
                        (typeof rebuildData === 'string' ? rebuildData : JSON.stringify(rebuildData, null, 2))
                    );
                    loadStatus();
                }, function () {
                    $('#nrd-settings-result').text('Settings saved and generated, but aggregate rebuild failed. Run Update Now or inspect the updater log.');
                    loadStatus();
                });
            }, function () {
                $('#nrd-settings-result').text('Settings were saved, but configd could not regenerate the settings file.');
            });
        });
    });

    $('#nrd-update').click(function () { action('/api/whoisdsnrd/service/update', 'Update'); });
    $('#nrd-refresh').click(function () { action('/api/whoisdsnrd/service/refresh', 'Refresh'); });
    $('#nrd-clear').click(function () {
        var ok = window.confirm('This will permanently delete all locally stored WhoisDS daily archives and empty the published NRD feed. Unbound DNSBL will then be refreshed to remove entries supplied by this feed. Continue?');
        if (ok) action('/api/whoisdsnrd/service/clear', 'Clear data');
    });
    $('#nrd-start').click(function () { action('/api/whoisdsnrd/service/start', 'Start'); });
    $('#nrd-stop').click(function () { action('/api/whoisdsnrd/service/stop', 'Stop'); });
    $('#nrd-restart').click(function () { action('/api/whoisdsnrd/service/restart', 'Restart'); });
    $('#nrd-reload').click(loadStatus);

    mapDataToFormUI({'frm_NRDSettings': '/api/whoisdsnrd/settings/get'});
    loadStatus();
    setInterval(loadStatus, 30000);
});
</script>
<div class="content-box">
 <div class="col-md-12">
  <h2>WhoisDS Newly Registered Domains</h2>
  <p>Daily free WhoisDS NRD collection with configurable rolling retention. The published list is consumed by Unbound DNSBL.</p>
  <div class="alert alert-info">The local HTTP endpoint must remain bound to 127.0.0.1:18765. Configure this URL in Unbound DNS &gt; Blocklists: <code>http://127.0.0.1:18765/nrd-15days.txt</code></div>
 </div>
 <div class="col-md-12">
  <h3>Feed Settings</h3>
  {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_NRDSettings'])}}
  <p class="help-block">TLD exclusions apply to the published aggregate only; downloaded daily archives are kept unchanged. For example, entering <code>ru,cn,xyz</code> removes all domains ending in those suffixes. Multi-label suffixes such as <code>co.uk</code> are also supported. Each remaining domain is published both as an apex entry and a wildcard rule (for example, <code>example.com</code> and <code>*.example.com</code>) so its subdomains are covered.</p>
  <p class="help-block">Saving settings reconciles the aggregate using the daily archives already stored on the firewall; it does not download more data. An aggregate rebuild occurs only when retention, exclusions, or archive files have changed. Update Now checks today's UTC archive first, falls back to yesterday if it is not yet published, and downloads only missing or invalid date archives. Unchanged archives are validated from saved file metadata. When the aggregate changes, the plugin invalidates only its own Unbound URL cache, runs a DNSBL update, and verifies that the complete feed was cached and the DNSBL database regenerated. Unchanged feeds skip the refresh unless the previous ingestion is still pending.</p>
  <p class="help-block">When increasing retention beyond the number of dates shown below, click <strong>Update Now</strong> after saving to fetch additional available history. WhoisDS free historical availability is limited, so older dates may not be recoverable.</p>
  <button class="btn btn-primary" id="nrd-save-settings" type="button">Save Settings &amp; Rebuild Feed</button>
  <pre id="nrd-settings-result" class="hidden" style="margin-top:12px;white-space:pre-wrap"></pre>
  <div id="nrd-settings-error" class="alert alert-danger hidden" style="margin-top:12px"></div>
 </div>
 <div class="col-md-12"><h3>Dashboard</h3>
  <table class="table table-striped"><tbody>
   <tr><th>HTTP service</th><td id="nrd-status">Loading…</td></tr>
   <tr><th>Local endpoint</th><td id="nrd-http">Loading…</td></tr>
   <tr><th>Unique apex domains published</th><td id="nrd-unique">—</td></tr>
   <tr><th>Published feed lines (apex + wildcards)</th><td id="nrd-lines">—</td></tr>
   <tr><th>Raw daily entries</th><td id="nrd-raw">—</td></tr>
   <tr><th>Domains excluded by TLD filter</th><td id="nrd-filtered">—</td></tr>
   <tr><th>Wildcard subdomain rules</th><td id="nrd-wildcards">—</td></tr>
   <tr><th>Configured TLD exclusions</th><td id="nrd-tlds">—</td></tr>
   <tr><th>Daily archives retained</th><td id="nrd-days">—</td></tr>
   <tr><th>Aggregate file</th><td id="nrd-output">—</td></tr>
   <tr><th>Newest feed date (UTC)</th><td id="nrd-anchor">Not established</td></tr>
   <tr><th>Last checked</th><td id="nrd-last-checked">Never</td></tr>
   <tr><th>Last successful update</th><td id="nrd-last-success">Never</td></tr>
   <tr><th>Last feed rebuild</th><td id="nrd-last-rebuild">Never</td></tr>
   <tr><th>Unbound ingestion</th><td id="nrd-unbound-state">unknown</td></tr>
   <tr><th>Last verified Unbound ingestion</th><td id="nrd-last-unbound">Never</td></tr>
   <tr><th>Unbound ingestion error</th><td id="nrd-unbound-error"></td></tr>
  </tbody></table>
  <div id="nrd-stats-note" class="alert alert-info hidden"></div>
  <button class="btn btn-primary" id="nrd-update" type="button">Update Now</button>
  <button class="btn btn-default" id="nrd-refresh" type="button">Force Refresh &amp; Verify Unbound</button>
  <button class="btn btn-danger" id="nrd-clear" type="button">Clear Data &amp; Start Fresh</button>
  <button class="btn btn-default" id="nrd-reload" type="button">Reload Status</button>
  <button class="btn btn-default" id="nrd-start" type="button">Start HTTP Service</button>
  <button class="btn btn-default" id="nrd-stop" type="button">Stop HTTP Service</button>
  <button class="btn btn-default" id="nrd-restart" type="button">Restart HTTP Service</button>
  <pre id="nrd-result" class="hidden" style="margin-top:12px;white-space:pre-wrap"></pre>
 </div>
 <div class="col-md-12"><h3>Daily Feed History</h3>
  <table class="table table-striped" id="nrd-days-table"><thead><tr><th>Feed date (UTC)</th><th>Raw domains</th><th>Archive size</th></tr></thead><tbody><tr><td colspan="3">Loading…</td></tr></tbody></table>
 </div>
 <div class="col-md-12"><h3>Automatic Updates</h3>
  <p>Use <strong>System &gt; Settings &gt; Cron</strong> to schedule <em>Update WhoisDS NRD feed and refresh Unbound DNSBL</em>. Recommended: daily at 05:15 local firewall time. The Cron entry is managed by OPNsense's native scheduler and remains visible with your other scheduled jobs.</p>
  <p><strong>Clear Data &amp; Start Fresh</strong> deletes this plugin’s stored daily archives and replaces the published feed with an empty list. It also requests an Unbound DNSBL refresh. The action does not delete plugin settings, logs, or unrelated Unbound blocklists. The next update starts collecting a fresh local history.</p>
  <p>The retention setting controls how many date buckets are kept in the aggregate (1–15). WhoisDS free historical availability is limited, typically to about 10 days, so increasing retention beyond the available history fills gradually as daily updates succeed.</p>
 </div>
</div>
