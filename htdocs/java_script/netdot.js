// netdot.js — shared client for the read-write detail pages.
// Edit forms (form[data-nd-api]) submit to the JSON API via fetch (single write
// path), then show a transient status box and reload on success.
(function () {
  'use strict';

  // fetch <method> <url> (same-origin, JSON body) -> {ok, status, data}.
  function api(method, url, body) {
    var opts = {
      method: method,
      headers: { 'Accept': 'application/json' },
      credentials: 'same-origin'
    };
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    return fetch(url, opts).then(function (r) {
      return r.text().then(function (txt) {
        var data;
        try { data = txt ? JSON.parse(txt) : {}; } catch (e) { data = { error: txt || ('HTTP ' + r.status) }; }
        return { ok: r.ok, status: r.status, data: data };
      });
    }).catch(function (e) {
      return { ok: false, status: 0, data: { error: String(e) } };
    });
  }

  // Transient status box, fixed at the bottom of the viewport.
  var box = null, timer = null;
  function status(ok, msg, ms) {
    if (!box) {
      box = document.createElement('div');
      box.className = 'nd-status';
      document.body.appendChild(box);
    }
    clearTimeout(timer);
    box.textContent = msg;
    box.className = 'nd-status ' + (ok ? 'ok' : 'err') + ' show';
    timer = setTimeout(function () {
      box.className = 'nd-status ' + (ok ? 'ok' : 'err');
    }, ms || 4000);
  }

  // Full-screen "busy" overlay with a spinner (a <div>, not a native dialog) shown
  // while a slow server-side write runs (e.g. a recursive Ipblock delete). Blocks
  // interaction until hidden.
  function spinner(show, msg) {
    var el = document.getElementById('nd-busy');
    if (show) {
      if (!el) {
        el = document.createElement('div');
        el.id = 'nd-busy';
        el.className = 'nd-busy';
        el.innerHTML = '<div class="nd-busy-card"><div class="nd-busy-spin"></div>' +
                       '<div class="nd-busy-msg"></div></div>';
        document.body.appendChild(el);
      }
      el.querySelector('.nd-busy-msg').textContent = msg || 'Please wait…';
      el.style.display = 'flex';
      document.body.style.overflow = 'hidden';
    } else if (el) {
      el.style.display = 'none';
      document.body.style.overflow = '';
    }
  }

  // Collect a form's named inputs/selects/textarea into a JSON body.
  // checkboxes -> true/false, selects -> id or null, others -> string.
  // Fields marked data-nd-int that hold a purely-numeric value are sent as an
  // integer (FK ids); non-numeric values (types, addresses) are left as strings.
  function collect(form) {
    var body = {};
    var els = form.querySelectorAll('input[name], select[name], textarea[name]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.type === 'checkbox') {
        body[el.name] = el.checked;
      } else if (el.hasAttribute('data-nd-int') && /^\d+$/.test(el.value)) {
        body[el.name] = parseInt(el.value, 10);
      } else if (el.tagName === 'SELECT') {
        body[el.name] = el.value === '' ? null : el.value;
      } else {
        body[el.name] = el.value;
      }
    }
    return body;
  }

  function initForms() {
    var forms = document.querySelectorAll('form[data-nd-api]');
    for (var i = 0; i < forms.length; i++) {
      forms[i].addEventListener('submit', function (e) {
        e.preventDefault();
        var form   = e.target;
        var method = form.getAttribute('data-nd-method') || 'POST';
        var url    = form.getAttribute('data-nd-api');
        var body   = collect(form);
        var btns   = form.querySelectorAll('button[type=submit]');
        for (var b = 0; b < btns.length; b++) { btns[b].disabled = true; }
        api(method, url, body).then(function (res) {
          if (res.ok) {
            // data-nd-redirect: go to the created object's detail page
            // (prefix ending in the object type + '/').
            var redirect = form.getAttribute('data-nd-redirect');
            if (redirect && res.data && res.data.id !== undefined) {
              status(true, 'Created');
              setTimeout(function () { location.href = redirect + res.data.id; }, 700);
            } else {
              status(true, 'Saved');
              setTimeout(function () { location.reload(); }, 700);
            }
          } else {
            var msg = (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
            status(false, msg, 8000);
            for (var b = 0; b < btns.length; b++) { btns[b].disabled = false; }
          }
        });
      });
    }
  }

  // FK picker: search box (large tables) -> API ?kw= -> fill the <select>.
  function escapeHtml(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function fkSearch(e) {
    var t    = e.target || e.srcElement;
    var wrap = t.closest('.nd-fk-search');
    if (!wrap) { return; }
    var kw   = wrap.querySelector('.nd-fk-kw');
    var sel  = wrap.querySelector('.nd-fk-select');
    var form = wrap.closest('form');
    var base = form ? form.getAttribute('data-nd-api-base') : '/api';
    var q    = (kw.value || '').trim();
    var url  = base + '/' + kw.getAttribute('data-nd-target') + '?kw=' + encodeURIComponent(q) +
               '&limit=' + (kw.getAttribute('data-nd-max') || 100);
    var curId = sel.value;
    api('GET', url).then(function (res) {
      var results = (res.ok && res.data && res.data.results) ? res.data.results : [];
      var html = '<option value="">-- Search --</option>';
      var found = false;
      for (var j = 0; j < results.length; j++) {
        html += '<option value="' + results[j].id + '">' + escapeHtml(results[j].label) + '</option>';
        if (String(results[j].id) === String(curId)) { found = true; }
      }
      if (curId && !found) { html += '<option value="' + curId + '" selected>current (' + curId + ')</option>'; }
      html += '<option value="">[null]</option>';
      sel.innerHTML = html;
      if (curId) { sel.value = curId; }
    });
  }

  function initFkSearch() {
    var btns = document.querySelectorAll('.nd-fk-go');
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', fkSearch);
      var wrap = btns[i].closest('.nd-fk-search');
      var kw   = wrap && wrap.querySelector('.nd-fk-kw');
      if (kw) {
        kw.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') { e.preventDefault(); fkSearch(e); }
        });
      }
    }
  }

  // Per-record Edit / Cancel toggle (related records on the RR host page): each
  // .nd-rec holds a readonly table (.nd-rec-ro) + a hidden form (.nd-rec-form).
  function initRecToggles() {
    var toggles = document.querySelectorAll('.nd-rec-toggle');
    for (var i = 0; i < toggles.length; i++) {
      toggles[i].addEventListener('click', function () {
        var wrap = this.closest('.nd-rec');
        var form = wrap && wrap.querySelector('form.nd-rec-form');
        var ro   = wrap && wrap.querySelector('.nd-rec-ro');
        if (form) { form.style.display = 'block'; }
        if (ro)   { ro.style.display = 'none'; }
      });
    }
    var cancels = document.querySelectorAll('.nd-rec-cancel');
    for (var j = 0; j < cancels.length; j++) {
      cancels[j].addEventListener('click', function () {
        var wrap = this.closest('.nd-rec');
        var form = wrap && wrap.querySelector('form.nd-rec-form');
        var ro   = wrap && wrap.querySelector('.nd-rec-ro');
        if (form) { form.style.display = 'none'; }
        if (ro)   { ro.style.display = 'block'; }
      });
    }
  }

  // Modal confirm dialog (a <div>, not a native confirm()). Native confirm()
  // triggers the browser's anti-dialog "don't ask again" permission prompt; a
  // custom div avoids that. Carries an optional checkbox so the choice is made in
  // ONE dialog (no second popup). Resolves {ok, check}: ok=false on Cancel/ESC.
  // Enter does NOT confirm (these are destructive); only the OK button does.
  function ndConfirm(opts) {
    opts = opts || {};
    return new Promise(function (resolve) {
      var ov = document.createElement('div');
      ov.className = 'nd-modal-ov';
      var card = document.createElement('div');
      card.className = 'nd-modal';
      var msg = document.createElement('div');
      msg.className = 'nd-modal-msg';
      msg.textContent = opts.message || '';
      card.appendChild(msg);
      var cb = null;
      if (opts.checkbox) {
        var lbl = document.createElement('label');
        lbl.className = 'nd-modal-check';
        cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !!opts.checkbox.defaultOn;
        lbl.appendChild(cb);
        lbl.appendChild(document.createTextNode(' ' + opts.checkbox.label));
        card.appendChild(lbl);
      }
      var row = document.createElement('div');
      row.className = 'nd-modal-row';
      var okBtn = document.createElement('button');
      okBtn.type = 'button';
      okBtn.className = 'btn nd-modal-ok';
      okBtn.textContent = opts.okLabel || 'OK';
      var cancelBtn = document.createElement('button');
      cancelBtn.type = 'button';
      cancelBtn.className = 'btn';
      cancelBtn.textContent = opts.cancelLabel || 'Cancel';
      row.appendChild(okBtn);
      row.appendChild(cancelBtn);
      card.appendChild(row);
      ov.appendChild(card);
      document.body.appendChild(ov);
      okBtn.focus();
      function done(ok) {
        document.removeEventListener('keydown', onKey, true);
        if (ov.parentNode) { ov.parentNode.removeChild(ov); }
        resolve({ ok: ok, check: cb ? cb.checked : false });
      }
      function onKey(e) { if (e.key === 'Escape') { done(false); } }
      document.addEventListener('keydown', onKey, true);
      okBtn.addEventListener('click', function () { done(true); });
      cancelBtn.addEventListener('click', function () { done(false); });
      ov.addEventListener('click', function (e) { if (e.target === ov) { done(false); } });
    });
  }

  // Delete buttons: confirm (modal), then DELETE <data-nd-del>, then reload — or
  // go to data-nd-goto when the deleted object IS the current page (page-level
  // delete). An Ipblock delete (data-nd-ipblock) offers the default-off choice to
  // also delete its children (recursive); when off the children are re-attached to
  // the block's parent. A device delete (data-nd-device) offers the default-off
  // choice to also remove its IP addresses / DNS A/AAAA records (see Device::delete).
  function initRecDeletes() {
    var dels = document.querySelectorAll('.nd-rec-delete');
    for (var i = 0; i < dels.length; i++) {
      dels[i].addEventListener('click', function () {
        var btn  = this;
        var url  = btn.getAttribute('data-nd-del');
        var goto = btn.getAttribute('data-nd-goto');
        if (!url) { return; }
        var opt = { message: (goto ? 'Delete this object and all its records?' : 'Delete this record?') };
        if (btn.getAttribute('data-nd-ipblock')) {
          opt.message = 'Delete this IP block?';
          var nch = parseInt(btn.getAttribute('data-nd-children') || '0', 10);
          if (nch > 0) {
            // Default off (Mason): unchecked -> children re-attached to the
            // block's parent (see Ipblock::delete / _tree_delete).
            opt.checkbox = { label: 'Also delete the ' + nch + ' child block(s). If unchecked, they will be re-attached to this block\'s parent.', defaultOn: false };
          }
        } else if (btn.getAttribute('data-nd-device')) {
          opt.message = 'Delete this device?\n\nIt will be moved to the available asset pool. If you intend to decommission the hardware, remember to remove the asset as well.';
          opt.checkbox = { label: 'Also delete this device\'s IP addresses and their DNS A/AAAA records.', defaultOn: false };
        }
        ndConfirm(opt).then(function (r) {
          if (!r.ok) { return; }
          var sep = (url.indexOf('?') === -1 ? '?' : '&');
          if (btn.getAttribute('data-nd-ipblock') && r.check) { url += sep + 'recursive=1'; }
          else if (btn.getAttribute('data-nd-device') && r.check) { url += sep + 'delete_ips=1'; }
          btn.disabled = true;
          spinner(true, 'Deleting…');
          api('DELETE', url).then(function (res) {
            spinner(false);
            if (res.ok) {
              status(true, 'Deleted');
              setTimeout(function () { goto ? (location.href = goto) : location.reload(); }, 700);
            } else {
              var msg = (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
              status(false, msg, 8000);
              btn.disabled = false;
            }
          });
        });
      });
    }
  }

  // List-page batch delete: checked rows -> ONE DELETE /api/<type>?id=1,2,3
  // (the server checks each id on its own and reports {deleted, skipped}).
  function initBatchDelete() {
    var btns   = document.querySelectorAll('button.nd-batch-delete');
    if (!btns.length) { return; }
    var checks = document.querySelectorAll('.nd-batch-check');
    var count  = document.querySelector('.nd-batch-count');
    function checkedIds() {
      var ids = [];
      for (var i = 0; i < checks.length; i++) {
        if (checks[i].checked) {
          var parts = (checks[i].name || '').split('__');
          var id    = parts[parts.length - 1];
          if (/^\d+$/.test(id)) { ids.push(id); }
        }
      }
      return ids;
    }
    function refresh() {
      var n = checkedIds().length;
      if (count) { count.textContent = n ? (n + ' selected') : ''; }
    }
    for (var i = 0; i < checks.length; i++) { checks[i].addEventListener('change', refresh); }
    for (var j = 0; j < btns.length; j++) {
      btns[j].addEventListener('click', function () {
        var btn  = this;
        var base = btn.getAttribute('data-nd-api');
        if (!base) { return; }
        var ids = checkedIds();
        if (!ids.length) { status(false, 'Select at least one row to delete', 4000); return; }
        ndConfirm({ message: 'Delete ' + ids.length + ' object(s)? This cannot be undone.' }).then(function (r) {
          if (!r.ok) { return; }
          btn.disabled = true;
          spinner(true, 'Deleting ' + ids.length + ' object(s)…');
          api('DELETE', base + '?id=' + ids.join(',')).then(function (res) {
            spinner(false);
            if (res.ok) {
              var skipped = (res.data && res.data.skipped) ? Object.keys(res.data.skipped).length : 0;
              status(true, 'Deleted ' + res.data.deleted.length + (skipped ? ' (' + skipped + ' skipped)' : ''), 5000);
              setTimeout(function () { location.reload(); }, 1000);
            } else {
              var msg = (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
              status(false, msg, 8000);
              btn.disabled = false;
            }
          });
        });
      });
    }
  }

  // "Add a record" section: a type <select> reveals the matching pre-rendered
  // form (submitted via POST by initForms). Cancel resets the select.
  function initAddForm() {
    var sel = document.getElementById('nd-add-type');
    if (!sel) { return; }
    var forms = document.querySelectorAll('form.nd-add-form');
    function show(type) {
      for (var i = 0; i < forms.length; i++) {
        forms[i].style.display = (forms[i].getAttribute('data-nd-type') === type) ? 'block' : 'none';
      }
    }
    sel.addEventListener('change', function () { show(sel.value); });
    var cancels = document.querySelectorAll('.nd-add-cancel');
    for (var j = 0; j < cancels.length; j++) {
      cancels[j].addEventListener('click', function () { sel.value = ''; show(''); });
    }
  }

  // Edit / Cancel toggle for the generic detail page.
  function initToggle() {
    var toggle   = document.getElementById('nd-edit-toggle');
    var form     = document.getElementById('nd-edit');
    var readonly = document.getElementById('nd-readonly');
    var cancel   = document.getElementById('nd-edit-cancel');
    if (!toggle) { return; }
    toggle.addEventListener('click', function () {
      if (form)     { form.style.display = 'block'; }
      if (readonly) { readonly.style.display = 'none'; }
    });
    if (cancel) {
      cancel.addEventListener('click', function () {
        if (form)     { form.style.display = 'none'; }
        if (readonly) { readonly.style.display = 'block'; }
      });
    }
  }

  // "Create block/IP" modal (Mason ADD_BLOCK): shown when clicking a free partition
  // (container view) or an unassigned address (subnet view). Confirms the creation of
  // a not-yet-existing IP address or block and lets the user pick the status —
  // block: Container/Reserved/Subnet (default Container); address: Static/Reserved
  // (+ Dynamic when the Subnet parent has DHCP). POSTs /api/ipblock, reloads on success.
  function ndCreateIpblock(opts) {
    var parts  = opts.address.split('/');
    var prefix = parts.length > 1 ? parseInt(parts[1], 10) : (parts[0].indexOf(':') >= 0 ? 128 : 32);
    var isAddr = (prefix === 32 || prefix === 128);
    var statuses = isAddr
      ? (['Static', 'Reserved'].concat(opts.dhcp ? ['Dynamic'] : []))
      : ['Container', 'Reserved', 'Subnet'];
    var defStatus = isAddr ? 'Static' : 'Container';
    return new Promise(function (resolve) {
      var ov = document.createElement('div'); ov.className = 'nd-modal-ov';
      var card = document.createElement('div'); card.className = 'nd-modal';
      var msg = document.createElement('div'); msg.className = 'nd-modal-msg';
      msg.textContent = 'The IP address or block ' + opts.address + ' does not yet exist. Are you sure that you want to create it?';
      card.appendChild(msg);
      var selWrap = document.createElement('div'); selWrap.className = 'nd-modal-field';
      var sel = document.createElement('select'); sel.className = 'nd-modal-select';
      for (var i = 0; i < statuses.length; i++) {
        var op = document.createElement('option');
        op.value = statuses[i]; op.textContent = statuses[i];
        if (statuses[i] === defStatus) { op.selected = true; }
        sel.appendChild(op);
      }
      selWrap.appendChild(sel);
      card.appendChild(selWrap);
      var row = document.createElement('div'); row.className = 'nd-modal-row';
      var okBtn = document.createElement('button'); okBtn.type = 'button'; okBtn.className = 'btn nd-modal-create'; okBtn.textContent = 'Create';
      var cancelBtn = document.createElement('button'); cancelBtn.type = 'button'; cancelBtn.className = 'btn'; cancelBtn.textContent = 'Cancel';
      row.appendChild(okBtn); row.appendChild(cancelBtn); card.appendChild(row);
      ov.appendChild(card); document.body.appendChild(ov); okBtn.focus();
      function close() {
        document.removeEventListener('keydown', onKey, true);
        if (ov.parentNode) { ov.parentNode.removeChild(ov); }
      }
      function onKey(e) { if (e.key === 'Escape') { close(); resolve({ ok: false }); } }
      document.addEventListener('keydown', onKey, true);
      okBtn.addEventListener('click', function () {
        var st = sel.value;
        okBtn.disabled = true;
        spinner(true, 'Creating ' + opts.address + '…');
        // API base derives from the page URL (…/<prefix>/management/… → <prefix>/api/ipblock);
        // the API auto-attaches the new block to its parent, so no `parent` in the body.
        var base = location.pathname.split('/management')[0] + '/api/ipblock';
        api('POST', base, { address: opts.address, status: st }).then(function (res) {
          spinner(false);
          if (res.ok) {
            // Go to the new block's detail page so the user can add info (description,
            // DNS A/AAAA record for a hostname, owner, …) right away.
            close(); status(true, 'Created');
            var pid = res.data && res.data.id;
            var prefix = location.pathname.split('/management')[0];
            setTimeout(function () { location.href = pid ? prefix + '/management/ipblock/' + pid : location.href.replace(/[?#].*$/, ''); }, 600);
            resolve({ ok: true });
          }
          else { close(); status(false, (res.data && res.data.error) ? res.data.error : ('Error ' + res.status), 8000); resolve({ ok: false }); }
        });
      });
      cancelBtn.addEventListener('click', function () { close(); resolve({ ok: false }); });
      ov.addEventListener('click', function (e) { if (e.target === ov) { close(); resolve({ ok: false }); } });
    });
  }

  // Clickable free cells — container free partitions + subnet unassigned addresses —
  // open the "create block/IP" modal above.
  function initCreateBlocks() {
    var cells = document.querySelectorAll('[data-nd-create]');
    for (var i = 0; i < cells.length; i++) {
      cells[i].addEventListener('click', function (e) {
        e.preventDefault();
        var cidr = this.getAttribute('data-nd-create');
        if (!cidr) { return; }
        ndCreateIpblock({
          address: cidr,
          dhcp:    this.getAttribute('data-nd-dhcp') === '1'
        });
      });
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    initForms();
    initToggle();
    initRecToggles();
    initRecDeletes();
    initAddForm();
    initFkSearch();
    initCreateBlocks();
  });

  window.ND = { api: api, status: status, collect: collect };
})();
