// Applies the saved theme before the first paint, so a dark-mode user never
// sees a white flash. Loaded as a file (not inline) to fit the panel's CSP.
(function () {
  var mode = 'system';
  try {
    mode =
      localStorage.getItem('nspanel.theme') ||
      (localStorage.getItem('themeDark') === '1' ? 'dark' : 'system');
  } catch {
    /* storage blocked: follow the OS */
  }
  var dark =
    mode === 'dark' || (mode === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.add(dark ? 'theme-dark' : 'theme-light');
})();
