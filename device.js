/* Haggerty Shop Tools: one phone, one person.
   The phone claims a name the first time the person checks out, returns or hands off (HagDevice.ensure),
   or on the first success on pages that don't gate yet (contents, surplus, trailers). After that every page
   shows "as <name>" with no dropdown, and every request carries the phone's token.
   Pages call:  HagDevice.init(opts)  HagDevice.token()  HagDevice.person()  HagDevice.claim(name)
*/
(function () {
  const SUPABASE_URL = "https://tdflgfuqjnwctadsjizz.supabase.co";
  const SUPABASE_ANON_KEY = "sb_publishable_w9xkQQE07152NL8faFVTwQ_LSJ9Hf_d";
  const CLAIM_NOTIFY_URL = "https://haggertybuilds.app.n8n.cloud/webhook/sb-device-claimed";
  const H = { 'apikey': SUPABASE_ANON_KEY, 'Authorization': 'Bearer ' + SUPABASE_ANON_KEY, 'Content-Type': 'application/json' };
  const TOKEN_KEY = 'haggerty_device_token';
  const PERSON_KEY = 'haggerty_device_person';

  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16); });
  }
  function store(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }
  function read(k) { try { return localStorage.getItem(k) || ''; } catch (e) { return ''; } }
  function token() { let t = read(TOKEN_KEY); if (!t) { t = uuid(); store(TOKEN_KEY, t); } return t; }
  function person() { return read(PERSON_KEY); }
  function label() { const ua = navigator.userAgent || ''; return /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) ? 'iPad' : /Android/.test(ua) ? 'Android' : 'Browser'; }

  async function rpc(fn, body) {
    const res = await fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, { method: 'POST', headers: H, body: JSON.stringify(body) });
    return res.json();
  }

  // Lock the name select to the linked person and show a small line instead of the dropdown.
  function lock(select, name, opts) {
    if (!select) return;
    if (![...select.options].some(o => o.value === name)) { const o = document.createElement('option'); o.value = name; o.textContent = name; select.appendChild(o); }
    select.value = name;
    select.disabled = true;
    select.style.display = 'none';
    let line = document.getElementById('hagDeviceLine');
    if (!line) {
      line = document.createElement('div');
      line.id = 'hagDeviceLine';
      line.style.cssText = 'display:flex;align-items:center;gap:10px;background:rgba(63,178,127,.10);border:1px solid rgba(63,178,127,.45);border-radius:12px;padding:12px 14px;font-size:15px;color:#f4f4f2;';
      select.parentNode.insertBefore(line, select.nextSibling);
    }
    line.innerHTML = '<span style="width:9px;height:9px;border-radius:50%;background:#3fb27f;flex-shrink:0;"></span><span>' + (opts.verb || 'Signed in') + ' as <b></b></span><span style="margin-left:auto;color:#9a9a9a;font-size:12px;">this phone</span>';
    line.querySelector('b').textContent = name;
    if (select.value === name) select.dispatchEvent(new Event('change', { bubbles: true }));
    // Pages rebuild the option list after the names load; keep the lock on when that happens.
    if (!select._hagObserver) {
      select._hagObserver = new MutationObserver(() => {
        const who = person(); if (!who) return;
        if (![...select.options].some(o => o.value === who)) { const o = document.createElement('option'); o.value = who; o.textContent = who; select.appendChild(o); }
        if (select.value !== who) { select.value = who; select.dispatchEvent(new Event('change', { bubbles: true })); }
        select.disabled = true; select.style.display = 'none';
      });
      select._hagObserver.observe(select, { childList: true });
    }
  }

  // Called by the page after its first successful action under a chosen name.
  async function claim(name) {
    if (!name) return { ok: false };
    if (person() === name) return { ok: true, isNew: false, person: name };
    let data = null;
    try { data = await rpc('claim_device', { p_token: token(), p_person: name, p_label: label() }); } catch (e) { return { ok: false, error: 'network' }; }
    if (data && data.ok) {
      store(PERSON_KEY, data.person);
      if (data.isNew) {
        // Tell the person their phone was linked (n8n emails them). Fire and forget.
        try { fetch(CLAIM_NOTIFY_URL, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: token(), person: data.person, label: label() }), keepalive: true }).catch(() => {}); } catch (e) {}
      }
      const sel = document.getElementById(HagDevice._selectId);
      if (sel) lock(sel, data.person, HagDevice._opts);
    }
    return data || { ok: false };
  }

  // Called by the page right before it submits a checkout, return or handoff.
  // A phone that is not linked yet gets linked to the chosen name first (after the person confirms),
  // so the server can check every request against the phone's token.
  // Returns { ok: true } to go ahead, or { ok: false } after telling the person why not.
  async function ensure(name) {
    if (!name) return { ok: false };
    const who = person();
    if (who) {
      if (who.toLowerCase() === String(name).toLowerCase()) return { ok: true };
      alert('This phone is linked to ' + who + '. You can only act as yourself. Ask Liam if this is wrong.');
      return { ok: false };
    }
    const msg = 'Link this phone to ' + name + '?\n\n'
      + 'Everything checked out or returned on this phone will be under ' + name + ' from now on, '
      + 'and ' + name + ' gets an email saying so. Only tap OK if you are ' + name + '.';
    if (!confirm(msg)) return { ok: false };
    const r = await claim(name);
    if (r && r.ok) return { ok: true };
    if (!HagDevice.required && (!r || r.error === 'network')) return { ok: true };  // not enforced yet: don't block on a bad signal
    alert((r && r.message) || 'Could not link this phone. Check your signal and try again.');
    return { ok: false };
  }

  // On load: if this phone is linked, lock the dropdown to that person. If the link was revoked, clear it.
  async function init(opts) {
    opts = opts || {};
    HagDevice._opts = opts;
    HagDevice._selectId = opts.selectId || 'name';
    const sel = document.getElementById(HagDevice._selectId);
    const cached = person();
    if (cached && sel) lock(sel, cached, opts);   // instant, then confirm with the server
    try {
      const data = await rpc('resolve_device', { p_token: token() });
      HagDevice.required = !!(data && data.required);
      if (data && data.ok && data.linked) {
        store(PERSON_KEY, data.person);
        if (sel) lock(sel, data.person, opts);
        if (opts.onLinked) opts.onLinked(data.person);
      } else {
        if (cached) {   // unlinked by admin: put the dropdown back
          store(PERSON_KEY, null);
          if (sel) { sel.disabled = false; sel.style.display = ''; sel.value = ''; }
          const line = document.getElementById('hagDeviceLine'); if (line) line.remove();
        }
        if (opts.onUnlinked) opts.onUnlinked();
      }
    } catch (e) { /* offline: keep whatever we had */ }
  }

  window.HagDevice = { init, token, person, claim, ensure, required: false, _opts: {}, _selectId: 'name' };
})();
