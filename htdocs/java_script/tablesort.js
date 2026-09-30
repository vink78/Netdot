/*
  TableSort - dependency-free, htmx-safe column sorting.
  Replaces the legacy kryogenix sorttable.js (unmaintained since 2007,
  one-shot init that breaks after htmx DOM swaps).

  How it works:
    - A single click listener on <document> (event delegation). Because the
      listener is never attached to table cells, htmx swapping new markup into
      the DOM cannot orphan it -> tables are sortable on every page, no
      re-initialisation needed.
    - Click a header cell of any <table class="sortable"> to sort by that
      column; click again to reverse. Column type (IPv4 vs numeric vs text)
      is auto-detected from the first non-empty data cell. IPv4 addresses
      sort numerically (octet by octet); text sorts case-insensitively.
    - Add class "ts-nosort" to a header cell to exempt that column.

  Markup expected: first <tr> is the header row (<th> cells). A <thead> is
  promoted automatically on first sort. Data rows may carry the zebra classes
  datatabler1/datatabler2, which are re-striped after each sort.
*/
(function () {
  'use strict';

  function trim(s) { return (s || '').replace(/^\s+|\s+$/g, ''); }
  function cellText(cell) { return trim(cell && cell.textContent); }

  function headerRow(table) {
    if (table.tHead && table.tHead.rows.length) return table.tHead.rows[0];
    return table.rows[0];
  }
  function bodyRows(table) {
    if (table.tBodies && table.tBodies.length) {
      return Array.prototype.slice.call(table.tBodies[0].rows);
    }
    return Array.prototype.slice.call(table.rows).slice(1);
  }

  // Promote the first row into <thead> so tHead = header, tBodies[0] = data.
  function normalize(table) {
    if (table.__tsNorm) return;
    if (!table.tHead || table.tHead.rows.length === 0) {
      var thead = document.createElement('thead');
      var first = table.rows[0];
      if (first) {
        thead.appendChild(first);
        table.insertBefore(thead, table.firstChild);
      }
    }
    table.__tsNorm = true;
  }

  function isNum(s) {
    var t = s.replace(/[^0-9.-]/g, '');
    return t !== '' && t !== '-' && t !== '.' && !isNaN(parseFloat(s));
  }
  function isIPv4(s) {
    if (!/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(s)) return false;
    var p = s.split('.');
    for (var i = 0; i < 4; i++) if (parseInt(p[i], 10) > 255) return false;
    return true;
  }
  // Weighted 32-bit value: o1*256^3 + o2*256^2 + o3*256 + o4 (fits exactly in
  // a JS double). Returns -1 for anything that is not a valid IPv4 address.
  function ipKey(s) {
    var p = s.split('.');
    if (p.length !== 4) return -1;
    var k = 0;
    for (var i = 0; i < 4; i++) {
      var o = parseInt(p[i], 10);
      if (isNaN(o) || o < 0 || o > 255) return -1;
      k = k * 256 + o;
    }
    return k;
  }
  function colType(table, col) {
    var rows = bodyRows(table);
    for (var i = 0; i < rows.length; i++) {
      var c = rows[i].cells[col];
      if (!c) continue;
      var t = cellText(c);
      if (t === '') continue;
      if (isIPv4(t)) return 'ip';
      return isNum(t) ? 'num' : 'str';
    }
    return 'str';
  }

  function sortTable(table, col, dir) {
    var rows = bodyRows(table);
    if (!rows.length) return;
    var type = colType(table, col);
    var arr = rows.slice();
    arr.sort(function (a, b) {
      var va = a.cells[col] ? cellText(a.cells[col]) : '';
      var vb = b.cells[col] ? cellText(b.cells[col]) : '';
      var r;
      if (type === 'num') {
        var na = parseFloat(va.replace(/[^0-9.-]/g, ''));
        var nb = parseFloat(vb.replace(/[^0-9.-]/g, ''));
        if (isNaN(na)) na = 0;
        if (isNaN(nb)) nb = 0;
        r = na - nb;
      } else if (type === 'ip') {
        r = ipKey(va) - ipKey(vb);
      } else {
        va = va.toLowerCase();
        vb = vb.toLowerCase();
        r = va < vb ? -1 : (va > vb ? 1 : 0);
      }
      return r;
    });
    if (dir < 0) arr.reverse();
    var target = (table.tBodies && table.tBodies.length) ? table.tBodies[0] : table;
    for (var i = 0; i < arr.length; i++) target.appendChild(arr[i]);
  }

  function clearIndicators(table) {
    var header = headerRow(table);
    Array.prototype.forEach.call(header.cells, function (c) {
      c.classList.remove('ts-asc', 'ts-desc');
    });
  }

  document.addEventListener('click', function (e) {
    var target = e.target;
    if (!target || !target.closest) return;
    if (target.closest('a')) return;          // let links behave normally
    var cell = target.closest('th,td');
    if (!cell) return;
    var table = cell.closest('table.sortable');
    if (!table) return;

    normalize(table);
    var header = headerRow(table);
    if (cell.parentNode !== header) return;   // only header cells sort
    var col = Array.prototype.indexOf.call(header.cells, cell);
    if (col < 0) return;
    if (cell.classList.contains('ts-nosort')) return;

    var dir = (table.__tsCol === col && table.__tsDir === 1) ? -1 : 1;
    sortTable(table, col, dir);
    clearIndicators(table);
    cell.classList.add(dir === 1 ? 'ts-asc' : 'ts-desc');
    table.__tsCol = col;
    table.__tsDir = dir;
  });
})();
