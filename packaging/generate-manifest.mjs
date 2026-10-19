// Generates dist/<version>/build-manifest.json and SHA256SUMS.txt from the
// final files. Run from the repository root: node packaging/generate-manifest.mjs
import { createHash } from 'node:crypto';
import { readFileSync, statSync, writeFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';

const version = '0.2.0';
const dist = join('dist', version);
const revision = readFileSync('.git/refs/heads/main', 'utf8').trim().slice(0, 7);
const dirty = true; // This build was produced from a working tree with changes.

const artifacts = [
  {
    path: 'windows-x64/YuanLian-0.2.0-windows-x64-setup.exe',
    platform: 'windows', arch: 'x64', role: 'installer',
    signing: 'unsigned',
    tests: {
      install_silent: 'passed', uninstall_silent: 'passed',
      installed_client_launch: 'passed', installed_quality_preview_entry: 'passed', standard_install_path_detection: 'passed', uninstall_removes_quality_preview: 'passed',
      remote_connect_from_installer: 'not_run',
    },
    evidence: ['docs/packaging.md', 'docs/evidence/quality-preview-moonlight-2026-10-19.md'],
    limitations: ['未代码签名', '未做 GUI 逐页点击；质量预览为外部 Moonlight，不经过远联安全闭环'],
  },
  {
    path: 'windows-x64/YuanLian-0.2.0-windows-x64-portable.zip',
    platform: 'windows', arch: 'x64', role: 'portable',
    signing: 'unsigned',
    tests: { build: 'passed', installer_payload_matches_release: 'passed', remote_connect: 'not_run_from_zip' },
    evidence: ['docs/packaging.md', 'docs/evidence/quality-preview-moonlight-2026-10-19.md'],
    limitations: ['未代码签名', '本轮未重新解压/启动便携 zip'],
  },
  {
    path: 'quality-preview/yuanlian-quality-preview-0.2.0-windows-x64.zip',
    platform: 'windows', arch: 'x64', role: 'quality-preview-moonlight-community',
    signing: 'unsigned; unmodified upstream GPL-3.0 binaries',
    tests: {
      package_sha256_pins: 'passed', no_runtime_credentials_or_pairing_state: 'passed',
      component_version_check: 'passed', ui_launch_detached: 'passed',
      loopback_1080p60_hevc_5min: 'passed',
      two_physical_devices: 'not_run', cross_nat: 'not_run',
      resolution_1440p_4k: 'not_run', audio_hdr_input_latency: 'not_run',
      yuanlian_ticket_host_approval_revocation: 'not_applicable_by_design',
    },
    evidence: ['docs/evidence/quality-preview-moonlight-2026-10-19.md'],
    limitations: [
      '社区、非商用；GPL-3.0 本身不禁止商用，商用需另行评估',
      '外部 Moonlight/Sunshine 进程，未嵌入 Flutter，不经过远联票据/撤权',
      '仅同机回环 1080p60 实测；未两物理机/跨 NAT/1440p/4K/10 分钟/音频/HDR/输入延迟',
      '未代码签名；仅 Windows x64',
    ],
  },
  {
    path: 'android/YuanLian-0.2.0-arm64-v8a-preview.apk',
    platform: 'android', arch: 'arm64-v8a', role: 'release-preview',
    signing: 'preview-key (CN=YuanLian Preview, sha256 e95efd397b72854472545bc490aaa72726cb5a70cc3490757dc64a2490859512)',
    tests: { build: 'passed', apksigner_verify: 'passed', install_x86_64_emulator: 'not_applicable_abi_mismatch', install_arm64_device: 'not_run' },
    evidence: ['docs/packaging.md', 'docs/evidence/m1-android-client.md'],
    limitations: ['预览签名，非正式发布密钥', '未在 arm64 实体设备安装', '本产物早于 2026-10-19 质量预览 UI 改动'],
  },
  {
    path: 'android/YuanLian-0.2.0-universal-preview.apk',
    platform: 'android', arch: 'arm64-v8a+armeabi-v7a+x86_64', role: 'universal-preview',
    signing: 'preview-key (CN=YuanLian Preview)',
    tests: { build: 'passed', apksigner_verify: 'passed', install_x86_64_emulator: 'passed', launch_emulator: 'passed' },
    evidence: ['docs/packaging.md', 'artifacts/android-release.png'],
    limitations: ['预览签名', '模拟器为 x86_64，不代表 arm64 真机', '本产物早于 2026-10-19 质量预览 UI 改动'],
  },
  {
    path: 'linux-x86_64/yuanlian-client_0.2.0_amd64.deb',
    platform: 'linux', arch: 'x86_64', role: 'deb',
    signing: 'unsigned',
    tests: { build: 'passed', dpkg_deb_info_contents: 'passed', ldd_missing: 'none', xvfb_launch: 'reached_flutter_engine', real_desktop_install: 'not_run' },
    evidence: ['docs/packaging.md'],
    limitations: ['WSL 构建/Xvfb 检查，未在真实 X11/Wayland 桌面安装验收', '本产物早于 2026-10-19 质量预览 UI 改动'],
  },
  {
    path: 'linux-x86_64/YuanLian-0.2.0-linux-x86_64-portable.tar.gz',
    platform: 'linux', arch: 'x86_64', role: 'portable',
    signing: 'unsigned',
    tests: { build: 'passed', ldd_missing: 'none', real_desktop_run: 'not_run' },
    evidence: ['docs/packaging.md'],
    limitations: ['未在真实 Linux 桌面运行', '本产物早于 2026-10-19 质量预览 UI 改动'],
  },
  {
    path: 'server-linux-x86_64/yl-server-0.2.0-linux-x86_64.tar.gz',
    platform: 'linux', arch: 'x86_64', role: 'control-server',
    signing: 'unsigned',
    tests: { build: 'passed', package_extract_run: 'passed', health: 'passed', ticket_key: 'passed', systemd_install: 'not_run', docker_compose: 'not_run' },
    evidence: ['docs/packaging.md', 'docs/evidence/b-auth-ticket-2026-10-18.md', 'docs/evidence/webui-r1-r6-2026-10-18.md'],
    limitations: ['未安装到 192.168.9.66 或其它生产机', 'Docker 定义未构建'],
  },
];

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

const entries = [];
for (const artifact of artifacts) {
  const full = join(dist, artifact.path);
  const stat = statSync(full);
  entries.push({
    ...artifact,
    size_bytes: stat.size,
    sha256: sha256(full),
  });
}

const manifest = {
  product: 'YuanLian',
  version,
  protocol_version: 2,
  android_version_code: 2,
  revision_short: revision,
  source_dirty: dirty,
  built_at_utc: new Date().toISOString(),
  build_environment: {
    os: 'Windows 11 26H2 build 26300 x64',
    rust: '1.99.1 x86_64-pc-windows-msvc',
    flutter: '3.47.7 stable / Dart 3.13.5',
    server_build: 'WSL Ubuntu 24.04 cargo 1.99.1 (Linux x86_64)',
    linux_client_build: 'WSL Ubuntu 24.04 Flutter Linux 3.47.7',
  },
  checks: {
    root_rust_tests: '28 passed',
    flutter_tests: '48 passed',
    server_tests: '10 passed',
    webui_api_tests: 'ALL_R_API_TESTS_PASSED',
    dart_analyze: 'no issues',
    rust_fmt_clippy: 'passed',
    server_fmt_clippy: 'passed (WSL)',
  },
  artifacts: entries,
  notes: [
    'source_dirty=true: artifacts were built from the working tree, not a committed clean release revision.',
    'Tickets, revocation, R1-R6 and WebUI APIs were tested against a local WSL control server, not the deployed 192.168.9.66 service. P2P/ICE/TURN are not implemented.',
    'No Windows code-signing certificate was available; Android uses a preview key outside the repository.',
    'Quality preview is an external Moonlight-qt 6.2.0 + Sunshine 2026.914.233613 GPL-3.0 bundle, community/non-commercial only; it bypasses YuanLian tickets, Host approval and revocation and is not an embedded/formal quality mode.',
    'Windows portable/setup and the quality preview zip were rebuilt on 2026-10-19 from the current working tree (including the quality preview UI). Android, Linux client and server artifacts are the earlier 0.2.0 builds and do not contain the quality preview entry.',
    'Linux install/run was not validated on a real desktop; only WSL build/ldd/Xvfb checks were performed.',
  ],
};

writeFileSync(join(dist, 'build-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
const sums = entries
  .map((entry) => `${entry.sha256}  ${entry.path}`)
  .sort()
  .join('\n') + '\n';
writeFileSync(join(dist, 'SHA256SUMS.txt'), sums);
console.log(`wrote ${entries.length} artifact entries to ${dist}`);
for (const entry of entries) {
  console.log(entry.sha256, entry.size_bytes, entry.path);
}
