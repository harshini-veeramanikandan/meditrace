// MediTrace front-end helpers
(function () {
  // ---- theme ----
  function applyTheme(t) {
    document.documentElement.setAttribute('data-bs-theme', t);
    var ic = document.getElementById('themeIcon');
    if (ic) ic.className = t === 'dark' ? 'bi bi-sun' : 'bi bi-moon-stars';
  }
  var saved = null;
  try { saved = localStorage.getItem('mt-theme'); } catch (e) {}
  applyTheme(saved || 'dark');
  window.toggleTheme = function () {
    var t = document.documentElement.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('mt-theme', t); } catch (e) {}
    applyTheme(t);
    location.reload();   // redraw charts and maps in the new colours
  };
  window.toggleSidebar = function () {
    document.querySelector('.sidebar').classList.toggle('open');
  };
})();

// colours shared by charts and maps
window.MT = {
  verdict: {
    GENUINE: '#10b981', COUNTERFEIT: '#ef4444', CLONED: '#f97316',
    SUSPICIOUS: '#d946ef', RECALLED: '#8b5cf6', EXPIRED: '#64748b'
  },
  risk: { HIGH: '#ef4444', MEDIUM: '#eab308', LOW: '#10b981' },
  dark: function () { return document.documentElement.getAttribute('data-bs-theme') === 'dark'; },
  chartDefaults: function () {
    if (!window.Chart) return;
    var dark = MT.dark();
    Chart.defaults.font.family = 'Inter, system-ui, sans-serif';
    Chart.defaults.font.size = 12;
    Chart.defaults.color = dark ? '#94a3b8' : '#64748b';
    Chart.defaults.borderColor = dark ? 'rgba(148,163,184,.12)' : 'rgba(15,23,42,.07)';
    Chart.defaults.plugins.legend.labels.usePointStyle = true;
    Chart.defaults.plugins.legend.labels.boxWidth = 8;
  },
  // Leaflet map on OpenStreetMap tiles (free, no API key).
  // Dark mode inverts the tiles with CSS; if OSM fails, switch to a second free provider.
  map: function (id, center, zoom) {
    var m = L.map(id, { zoomControl: true, attributionControl: true }).setView(center || [22.5, 80], zoom || 4.6);
    var providers = [
      ['https://tile.openstreetmap.org/{z}/{x}/{y}.png', '&copy; OpenStreetMap contributors'],
      ['https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png', '&copy; OpenStreetMap contributors, HOT']
    ];
    var i = 0, errors = 0, layer = null;
    function add() {
      layer = L.tileLayer(providers[i][0], { maxZoom: 18, attribution: providers[i][1], className: 'map-tiles' });
      layer.on('tileerror', function () {
        errors += 1;
        if (errors > 4 && i < providers.length - 1) { m.removeLayer(layer); i += 1; errors = 0; add(); }
      });
      layer.addTo(m);
    }
    add();
    return m;
  }
};

// optional auto-refresh (Overview / Alerts)
window.setupAutoRefresh = function (checkboxId, seconds) {
  var cb = document.getElementById(checkboxId);
  if (!cb) return;
  var key = 'mt-refresh-' + location.pathname, timer = null;
  try { cb.checked = localStorage.getItem(key) === '1'; } catch (e) {}
  function arm() {
    clearTimeout(timer);
    if (cb.checked) timer = setTimeout(function () { location.reload(); }, seconds * 1000);
  }
  cb.addEventListener('change', function () {
    try { localStorage.setItem(key, cb.checked ? '1' : '0'); } catch (e) {}
    arm();
  });
  arm();
};

// client-side filter for card grids and tables (data-search attribute)
window.filterCards = function (text, selector) {
  var t = (text || '').toLowerCase().trim();
  document.querySelectorAll(selector).forEach(function (el) {
    el.style.display = !t || (el.getAttribute('data-search') || '').indexOf(t) !== -1 ? '' : 'none';
  });
};
