// Counts real DOM clicks. Deliberately trivial so a miscount means the input
// path is wrong, not this page.
let n = 0;
const out = document.getElementById('count');
document.getElementById('target').addEventListener('click', () => {
  n += 1;
  out.textContent = String(n);
});
document.getElementById('reset').addEventListener('click', (e) => {
  e.stopPropagation();
  n = 0;
  out.textContent = '0';
});
