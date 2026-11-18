'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require form';
'require poll';
'require dom';

/*
 * LuCI > Network > VPN - front end for /usr/sbin/wgswitch.
 *
 * Everything goes through the wgswitch CLI. Anything that changes the
 * network (connect, disconnect, test) is queued with --bg for the procd
 * service, so rpcd's exec timeout can never cut it off halfway; this page
 * just polls status (every 30 s, faster for a short while after an action).
 */

const CLI = '/usr/sbin/wgswitch';
const UPLOAD_TMP = '/tmp/wgswitch-upload.conf';
const EDIT_TMP = '/tmp/wgswitch-edit.conf';
const POLL_SECONDS = 30;

function run(args) {
	return fs.exec(CLI, args).then(function(res) {
		if (res.code !== 0) {
			const msg = ((res.stderr || '') + (res.stdout || '')).trim();
			throw new Error(msg || _('wgswitch exited with code %d').format(res.code));
		}
		return res.stdout || '';
	});
}

function runJSON(args) {
	return run(args).then(function(out) { return JSON.parse(out); });
}

function notifyError(err) {
	ui.addNotification(null, E('p', {}, [ err.message || String(err) ]), 'danger');
}

function fmtAge(sec) {
	if (sec == null || sec < 0) return _('never');
	return _('%s ago').format('%t'.format(sec));
}

function fmtBytes(n) {
	return '%1024.2mB'.format(n || 0);
}

function stateLabel(st) {
	switch (st.state) {
	case 'ok': return [ 'success', _('Connected') ];
	case 'degraded': return [ 'warning', _('Connected - failing health checks') ];
	case 'blocked': return [ 'danger', _('Tunnel down - kill switch is blocking traffic') ];
	case 'failover': return [ 'warning', _('Tunnel down - switching to another server') ];
	case 'fallback-direct': return [ 'warning', _('Disconnected by the kill switch - traffic goes out directly') ];
	default:
		return st.enabled ? [ 'notice', _('Connected (waiting for first health check)') ]
		                  : [ 'notice', _('Disconnected - traffic goes out directly') ];
	}
}

function testLabel(t) {
	if (!t || !t.status) return E('em', {}, _('not tested'));
	if (t.status === 'ok') return E('span', {}, _('%d ms handshake').format(t.ms));
	if (t.status === 'active') return E('span', {}, _('connected - see status above'));
	return E('span', { 'style': 'color:var(--error-color-high, #c00)' }, _('failed: %s').format(t.detail || t.status));
}

return view.extend({
	load: function() {
		return Promise.all([
			runJSON([ 'status', '--json' ]).catch(function(e) { return { error: e.message }; }),
			runJSON([ 'list', '--json' ]).catch(function() { return []; }),
			uci.load('wgswitch')
		]);
	},

	/* ---------------------------------------------------------------- status */

	renderStatus: function(st) {
		if (st.error)
			return E('div', { 'class': 'alert-message warning' }, [ E('p', {}, st.error) ]);

		const lbl = stateLabel(st);
		const rows = [
			[ _('State'), E('span', { 'class': 'label ' + lbl[0] }, lbl[1]) ],
			[ _('Server'), st.profile ? '%s (%s)'.format(st.profile, st.endpoint || '?') : '-' ],
			[ _('Interface'), '%s (%s)'.format(st.interface, st.up ? _('up') : _('down')) ]
		];
		if (st.up) {
			rows.push([ _('Last handshake'), fmtAge(st.handshake_age) ]);
			rows.push([ _('Health'), (st.rtt_ms != null)
				? _('RTT %s ms, packet loss %s%%').format(st.rtt_ms, st.loss_pct)
				: (st.loss_pct != null ? _('no reply (loss %s%%)').format(st.loss_pct) : _('not checked yet')) ]);
			rows.push([ _('Transfer'), _('received %s, sent %s').format(fmtBytes(st.rx), fmtBytes(st.tx)) ]);
		}
		rows.push([ _('Kill switch'), st.killswitch ]);
		if (st.busy) rows.push([ _('Working'), E('em', { 'class': 'spinning' }, st.busy) ]);
		if (st.test) {
			const p = st.test.split(' ');
			rows.push([ _('Server test'), p[0] === 'done'
				? _('finished: %s servers tested').format(p[2])
				: _('%s: %s of %s').format(p[0], p[1], p[2]) ]);
		}
		if (st.event) rows.push([ _('Last event'), st.event ]);
		if (!st.daemon)
			rows.push([ _('Warning'), E('strong', {}, _('The wgswitch service is not running: no health checks, no kill switch. Start it under System > Startup.')) ]);

		return E('table', { 'class': 'table' }, rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '25%' }, r[0]),
				E('td', { 'class': 'td left' }, r[1])
			]);
		}));
	},

	/* -------------------------------------------------------------- profiles */

	renderProfiles: function(list, st) {
		const self = this;
		const busy = !!(st && (st.busy || (st.test && st.test.split(' ')[0] !== 'done')));
		const head = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Profile')),
			E('th', { 'class': 'th' }, _('Endpoint')),
			E('th', { 'class': 'th' }, _('Last test')),
			E('th', { 'class': 'th cbi-section-actions' }, '')
		]);
		const rows = (list || []).map(function(p) {
			const btns = [];
			if (p.valid && !p.active)
				btns.push(E('button', { 'class': 'btn cbi-button cbi-button-apply', 'disabled': busy ? true : null,
					'click': ui.createHandlerFn(self, 'handleConnect', p.name) }, _('Connect')));
			if (p.valid && !p.active)
				btns.push(E('button', { 'class': 'btn cbi-button', 'disabled': busy ? true : null,
					'click': ui.createHandlerFn(self, 'handleTest', [ p.name ]) }, _('Test')));
			btns.push(E('button', { 'class': 'btn cbi-button cbi-button-edit',
				'click': ui.createHandlerFn(self, 'handleEdit', p.name) }, _('Edit')));
			if (!p.active)
				btns.push(E('button', { 'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(self, 'handleRemove', p.name) }, _('Delete')));
			return E('tr', { 'class': 'tr' + (p.active ? ' cbi-rowstyle-2' : '') }, [
				E('td', { 'class': 'td' }, p.active ? E('strong', {}, '%s ✓'.format(p.name)) : p.name),
				E('td', { 'class': 'td' }, p.valid ? p.endpoint : E('em', {}, _('invalid: %s').format(p.error))),
				E('td', { 'class': 'td' }, testLabel(p.test)),
				E('td', { 'class': 'td cbi-section-actions' }, E('div', {}, btns))
			]);
		});
		if (!rows.length)
			rows.push(E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 4 }, E('em', {}, _('No profiles yet. Add a .conf file, or copy files into the profile folder.')))
			]));
		return E('table', { 'class': 'table cbi-section-table' }, [ head ].concat(rows));
	},

	/* ------------------------------------------------------------- refresh */

	refresh: function() {
		const self = this;
		return Promise.all([
			runJSON([ 'status', '--json' ]).catch(function(e) { return { error: e.message }; }),
			runJSON([ 'list', '--json' ]).catch(function() { return null; })
		]).then(function(r) {
			self.lastStatus = r[0];
			dom.content(self.statusNode, self.renderStatus(r[0]));
			if (r[1]) dom.content(self.profilesNode, self.renderProfiles(r[1], r[0]));
			dom.content(self.actionsNode, self.renderActions(r[0]));
			return r[0];
		});
	},

	/* After an action, follow it every 3 s (for up to 3 minutes) until the
	 * service is idle again; the regular poll stays at 30 s. */
	follow: function() {
		const self = this;
		let n = 0;
		if (self.following) return;
		self.following = true;
		const tick = function() {
			self.refresh().then(function(st) {
				const testing = st && st.test && st.test.split(' ')[0] !== 'done';
				if (++n < 60 && st && (st.busy || testing)) {
					window.setTimeout(tick, 3000);
				} else {
					self.following = false;
				}
			}).catch(function() { self.following = false; });
		};
		window.setTimeout(tick, 1500);
	},

	queue: function(args, msg) {
		const self = this;
		return run(args).then(function() {
			ui.addTimeLimitedNotification(null, E('p', {}, msg), 4000, 'info');
			self.follow();
		}).catch(notifyError);
	},

	/* ------------------------------------------------------------- actions */

	handleConnect: function(name) {
		return this.queue([ 'connect', '--bg', name ], _('Connecting to %s…').format(name));
	},

	handleDisconnect: function() {
		const self = this;
		ui.showModal(_('Disconnect VPN'), [
			E('p', {}, _('Traffic will go out directly, without the VPN, until you connect again.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					ui.hideModal();
					self.queue([ 'disconnect', '--bg' ], _('Disconnecting…'));
				} }, _('Disconnect'))
			])
		]);
	},

	handleReconnect: function() {
		return this.queue([ 'reconnect', '--bg' ], _('Reconnecting…'));
	},

	handleTest: function(names) {
		return this.queue([ 'test', '--bg' ].concat(names || []),
			names && names.length ? _('Testing %s…').format(names.join(', ')) : _('Testing all servers…'));
	},

	handleUpload: function() {
		const self = this;
		return ui.uploadFile(UPLOAD_TMP).then(function(res) {
			const suggested = ((res && res.name) || '').replace(/\.conf$/i, '').replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\.+/, '');
			const input = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': suggested, 'placeholder': 'e.g. AU-45' });
			ui.showModal(_('Add profile'), [
				E('p', {}, _('Profile name (letters, digits, dot, dash, underscore):')),
				input,
				E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
					E('button', { 'class': 'btn', 'click': function() {
						ui.hideModal(); fs.remove(UPLOAD_TMP).catch(function() {});
					} }, _('Cancel')), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(self, function() {
						const name = input.value.trim();
						if (!/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/.test(name)) {
							ui.addNotification(null, E('p', {}, _('Invalid profile name')), 'danger');
							return;
						}
						return run([ 'add', UPLOAD_TMP, name ]).then(function(out) {
							ui.hideModal();
							ui.addTimeLimitedNotification(null, E('p', {}, out.trim()), 5000, 'info');
							return self.refresh();
						}).catch(notifyError).finally(function() { fs.remove(UPLOAD_TMP).catch(function() {}); });
					}) }, _('Add'))
				])
			]);
		}).catch(function(e) { if (e && e.message !== 'Upload has been cancelled') notifyError(e); });
	},

	handleEdit: function(name) {
		const self = this;
		return run([ 'show', name, '--secrets' ]).then(function(text) {
			const ta = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%; font-family:monospace', 'rows': 18, 'spellcheck': 'false' }, [ text ]);
			ui.showModal(_('Edit profile: %s').format(name), [
				E('p', {}, _('wg-quick format. The file is checked before it is saved; keys stay on this router.')),
				ta,
				E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'btn cbi-button-save', 'click': ui.createHandlerFn(self, function() {
						return fs.write(EDIT_TMP, ta.value.replace(/\r\n/g, '\n'), 384 /* 0600 */).then(function() {
							return run([ 'add', EDIT_TMP, name, '--replace' ]);
						}).then(function(out) {
							ui.hideModal();
							ui.addTimeLimitedNotification(null, E('p', {}, out.trim()), 6000, 'info');
							return self.refresh();
						}).catch(notifyError).finally(function() { fs.remove(EDIT_TMP).catch(function() {}); });
					}) }, _('Save'))
				])
			]);
		}).catch(notifyError);
	},

	handleRemove: function(name) {
		const self = this;
		ui.showModal(_('Delete profile'), [
			E('p', {}, _('Delete profile "%s"? The .conf file is removed from the router.').format(name)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(self, function() {
					return run([ 'remove', name ]).then(function() {
						ui.hideModal(); return self.refresh();
					}).catch(function(e) { ui.hideModal(); notifyError(e); });
				}) }, _('Delete'))
			])
		]);
	},

	renderActions: function(st) {
		const busy = !!(st && (st.busy || (st.test && st.test.split(' ')[0] !== 'done')));
		const dis = busy ? true : null;
		const btns = [
			E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleUpload') }, _('Add profile…')), ' ',
			E('button', { 'class': 'btn cbi-button', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleTest', []) }, _('Test all servers')), ' '
		];
		if (st && st.enabled) {
			btns.push(E('button', { 'class': 'btn cbi-button', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleReconnect') }, _('Reconnect')), ' ');
			btns.push(E('button', { 'class': 'btn cbi-button cbi-button-negative', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleDisconnect') }, _('Disconnect')));
		}
		return E('div', {}, btns);
	},

	/* -------------------------------------------------------------- render */

	render: function(data) {
		const self = this;
		const st = data[0], list = data[1];

		this.statusNode = E('div', {}, this.renderStatus(st));
		this.actionsNode = E('div', { 'style': 'margin:1em 0' }, this.renderActions(st));
		this.profilesNode = E('div', {}, this.renderProfiles(list, st));

		const m = new form.Map('wgswitch', _('Settings'),
			_('Saved settings apply on the next health check. Changing the interface or profile folder takes effect on the next connect.'));
		const s = m.section(form.NamedSection, 'main', 'wgswitch');
		s.addremove = false;

		let o = s.option(form.ListValue, 'killswitch', _('Kill switch'),
			_('What happens when the connected tunnel stops working.'));
		o.value('fastest', _('Fastest - switch to the fastest other server that passes traffic'));
		o.value('block', _('Block - no internet until the tunnel recovers'));
		o.value('direct', _('Direct - disconnect and go out without the VPN'));
		o.default = 'fastest';

		o = s.option(form.ListValue, 'fallback', _('If no server works'),
			_('Last resort for <em>Fastest</em> when no other server passes traffic.'));
		o.value('direct', _('Direct - disconnect and go out without the VPN'));
		o.value('block', _('Block - stay on the current server, no internet until it recovers'));
		o.default = 'direct';
		o.depends('killswitch', 'fastest');

		o = s.option(form.Value, 'interface', _('VPN interface'),
			_('netifd interface (and WireGuard device) that wgswitch manages, e.g. <code>wg0</code> or <code>vpn</code>. Your firewall zone should match this device.'));
		o.datatype = 'and(minlength(1),maxlength(15))';
		o.validate = function(id, v) { return /^[A-Za-z0-9_]+$/.test(v) || _('Letters, digits and _ only'); };
		o.default = 'wg0';

		o = s.option(form.Value, 'conf_dir', _('Profile folder'), _('Every <code>*.conf</code> file here is a profile.'));
		o.placeholder = '/etc/wireguard';

		o = s.option(form.ListValue, 'route_mode', _('Routing'));
		o.value('split', _('Full tunnel via 0.0.0.0/1 + 128.0.0.0/1 (keeps your default route underneath)'));
		o.value('allowed_ips', _('netifd "Route Allowed IPs"'));
		o.value('none', _('No routes (routing handled elsewhere, e.g. pbr)'));
		o.default = 'split';

		o = s.option(form.Value, 'check_interval', _('Health check interval (s)'));
		o.datatype = 'range(5,3600)'; o.placeholder = '15';
		o = s.option(form.Value, 'fail_threshold', _('Failed checks before the kill switch acts'));
		o.datatype = 'range(1,100)'; o.placeholder = '3';
		o = s.option(form.Value, 'handshake_timeout', _('Max handshake age (s)'));
		o.datatype = 'range(30,3600)'; o.placeholder = '180';
		o = s.option(form.DynamicList, 'ping_target', _('Health ping targets'), _('Pinged through the tunnel.'));
		o.datatype = 'ipaddr';
		o = s.option(form.Value, 'probe_timeout', _('Server test timeout (s)'));
		o.datatype = 'range(1,30)'; o.placeholder = '7';
		o = s.option(form.Value, 'failover_candidates', _('Servers tested on failover'));
		o.datatype = 'range(1,100)'; o.placeholder = '5';
		o = s.option(form.Value, 'hook', _('Hook script'),
			_('Optional executable, run with <code>connect</code> after connecting from a disconnected state and with <code>disconnect</code> before disconnecting.'));
		o.placeholder = '/etc/wgswitch/hook.sh';

		poll.add(function() { return self.refresh(); }, POLL_SECONDS);

		return m.render().then(function(mapNode) {
			return E('div', {}, [
				E('h2', {}, _('VPN')),
				E('div', { 'class': 'cbi-map-descr' }, _('WireGuard client profiles managed by wgswitch.')),
				E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Status')), self.statusNode, self.actionsNode ]),
				E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Profiles')), self.profilesNode ]),
				mapNode
			]);
		});
	}
});
