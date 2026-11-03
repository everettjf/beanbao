const copyButton = document.querySelector('[data-copy-target]');
const copyStatus = document.getElementById('copy-status');
const chinese = document.documentElement.lang.toLowerCase().startsWith('zh');

if (copyButton && copyStatus) {
  copyButton.addEventListener('click', async () => {
    const source = document.getElementById(copyButton.dataset.copyTarget);
    if (!source) return;

    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      copyButton.textContent = chinese ? '已复制' : 'Copied';
      copyStatus.textContent = chinese ? '安装命令已复制到剪贴板。' : 'Install commands copied to clipboard.';
      window.setTimeout(() => { copyButton.textContent = chinese ? '复制' : 'Copy'; }, 2000);
    } catch {
      copyStatus.textContent = chinese ? '当前无法自动复制，请选中命令手动复制。' : 'Copy is unavailable here. Select the commands and copy them manually.';
    }
  });
}
