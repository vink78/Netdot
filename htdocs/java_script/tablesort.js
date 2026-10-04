/*
  TableSort - dependency-free, htmx-safe column sorting.
  Replaces the legacy kryogenix sorttable.js (unmaintained since 2007,
  one-shot init that breaks after htmx DOM swaps).

  How it works:
    - A single click listener on <document> (event delegation). Because the
      listener is never attached to table cells, htmx swapping new markup into
      the DOM cannot orphan it -> tables are sortable on every page, no
      re-initialisation needed.
     - Click a header cell of a <table class="datatable sortable"> to sort by
       that column; click again to reverse. class="datatable" is the modern
       table LOOK (every table has it); class="sortable" opts a table into JS
       sorting (reserved for large list pages). Detail / field tables use
       class="datatable" only, so they are not sortable. Column type
       (IPv4 vs numeric vs text) is auto-detected from the first non-empty
       data cell. Detection is
      start-anchored, so a leading value in a longer string is honoured:
        * IPv4 -> sorted by the dotted quad, incl. CIDR (10.0.0.0/8); the
          /prefix is a tie-break (broad -> specific).
        * Numbers -> sorted by the leading number ("42 items" -> 42).
        * Text  -> sorted case-insensitively.
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

  // Numbers: the value *starts with* a number (optional sign, optional
  // decimal part). It may be the lead of a longer string ("42 items"); only
  // that leading number is used to sort.
  function isNum(s) {
    return /^-?\d+(?:\.\d+)?/.test(s);
  }
  function numKey(s) {
    var m = s.match(/^-?\d+(?:\.\d+)?/);
    var n = m ? parseFloat(m[0]) : 0;
    return isNaN(n) ? 0 : n;
  }

  // IPv4: the value *starts with* a dotted quad (each octet 0-255). The start
  // anchor (no trailing $) also catches CIDR ("10.0.0.0/8") and an IP that
  // prefixes a longer string.
  function isIPv4(s) {
    var m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/);
    if (!m) return false;
    for (var i = 1; i <= 4; i++) if (parseInt(m[i], 10) > 255) return false;
    return true;
  }
  // Sort key for an IPv4 value: the leading dotted quad as a weighted 32-bit
  // number (fits exactly in a JS double), with the optional /prefix as a
  // tie-break so the same network lists broad -> specific (/8 < /24 < /32).
  // Returns -1 when the value does not start with a valid IPv4.
  function ipKey(s) {
    var m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?/);
    if (!m) return -1;
    for (var i = 1; i <= 4; i++) if (parseInt(m[i], 10) > 255) return -1;
    var ip = parseInt(m[1], 10) * 16777216 + parseInt(m[2], 10) * 65536 +
             parseInt(m[3], 10) * 256 + parseInt(m[4], 10);
    var prefix = m[5] !== undefined ? parseInt(m[5], 10) : 0;
    if (prefix > 32) prefix = 0;
    return ip * 33 + prefix;
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
        r = numKey(va) - numKey(vb);
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
