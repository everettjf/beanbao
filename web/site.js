const copyButton = document.querySelector('[data-copy-target]');
const copyStatus = document.getElementById('copy-status');

if (copyButton && copyStatus) {
  copyButton.addEventListener('click', async () => {
    const source = document.getElementById(copyButton.dataset.copyTarget);
    if (!source) return;

    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      copyButton.textContent = 'Copied';
      copyStatus.textContent = 'Install commands copied to clipboard.';
      window.setTimeout(() => { copyButton.textContent = 'Copy'; }, 2000);
    } catch {
      copyStatus.textContent = 'Copy is unavailable here. Select the commands and copy them manually.';
    }
  });
}
