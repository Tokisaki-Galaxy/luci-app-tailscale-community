## Copilot Agent 运行环境说明
 - **预装工具**：
    - `jq` (JSON 处理)
    - `xvfb` (虚拟显示)
    - `tree` (查看目录结构)
    - `ripgrep` (高性能文本搜索)
    - **Playwright (Chromium)**：优先用于验证渲染、执行 E2E 测试或查看动态内容。
 - **OpenWrt 调试环境**：
    - **Docker 镜像**：已预装并缓存 `openwrt/rootfs:x86-64-23.05.5` 镜像（包含完整的 `opkg` 源）。
    - **LuCI 源码**：项目根目录下已克隆 `openwrt/luci` 仓库 (depth=1)，用于同步 `.po` 翻译文件。
    - **跨架构支持**：`qemu-user-static` 和 `binfmt-support` 用于模拟不同 CPU 架构
    - **编译工具链**：`build-essential`, `ccache`, `gawk`, `gettext`, `libncurses5-dev`, `libssl-dev`, `rsync`, `unzip`, `zlib1g-dev`
    - **网络调试工具**：`socat`, `netcat-openbsd`, `sshpass`
### ⚠️ 关键：LuCI 服务启动顺序
LuCI Web界面依赖多个服务，**必须按以下顺序启动**：
1. **ubusd** - ubus 消息总线（所有 ubus 服务的基础）
2. **procd** - 进程管理器（提供 `system` ubus 服务，LuCI header.ut 模板依赖 `ubus.call('system', 'board')`）
3. **rpcd** - RPC 守护进程（处理 ucode 插件和 RPC 调用）
4. **uhttpd** - Web 服务器
**不按此顺序启动会导致**：
- `Failed to connect to ubus` 错误
- LuCI 页面显示 `Error: left-hand side expression is null`（因为 `ubus.call('system', 'board')` 返回 null）
### 启动 LuCI 环境的推荐方式
```bash
# 方式1：后台启动容器后手动启动服务（推荐用于调试）
docker run -d --name openwrt-luci -p 8080:80 openwrt/rootfs:x86-64-23.05.5 tail -f /dev/null
# 进入容器安装 LuCI
docker exec openwrt-luci sh -c "mkdir -p /var/lock /var/run && opkg update && opkg install luci luci-base luci-compat"
# 按正确顺序启动服务
docker exec openwrt-luci /sbin/ubusd &
sleep 1
docker exec openwrt-luci /sbin/procd &
sleep 2
docker exec openwrt-luci /sbin/rpcd &
sleep 1
docker exec openwrt-luci /usr/sbin/uhttpd -f -h /www -r OpenWrt -x /cgi-bin -u /ubus -t 60 -T 30 -A 1 -n 3 -N 100 -R -p 0.0.0.0:80 &
# 设置 root 密码（用于 LuCI 登录）
docker exec -it openwrt-luci sh -c 'echo -e "password\npassword" | passwd root'
# 添加 bootstrap 主题配置（防止渲染错误）
docker exec openwrt-luci sh -c 'uci set luci.themes.Bootstrap=/luci-static/bootstrap && uci commit luci'
# 验证服务是否正常
docker exec openwrt-luci ubus list | grep -E "system|luci|tailscale"
# 此时可通过 Playwright 或浏览器访问 http://localhost:8080
```
```bash
# 方式2：一键启动脚本（适合快速验证）
docker run -d --name openwrt-luci -p 8080:80 openwrt/rootfs:x86-64-23.05.5 /bin/ash -c '
mkdir -p /var/lock /var/run
opkg update && opkg install luci luci-base luci-compat
# 关键：按顺序启动服务
/sbin/ubusd &
sleep 1
/sbin/procd &
sleep 2
/sbin/rpcd &
sleep 1
/usr/sbin/uhttpd -f -h /www -r OpenWrt -x /cgi-bin -u /ubus -t 60 -T 30 -A 1 -n 3 -N 100 -R -p 0.0.0.0:80 &
# 设置密码
echo -e "password\npassword" | passwd root
# 配置主题
uci set luci.themes.Bootstrap=/luci-static/bootstrap && uci commit luci
echo "LuCI is ready at http://localhost:8080 (root/password)"
tail -f /dev/null
'
```
### 部署插件文件到容器
```bash
# 复制前端文件
docker cp luci-app-tailscale-community/htdocs/luci-static/resources/view/tailscale.js \
  openwrt-luci:/www/luci-static/resources/view/tailscale.js
# 复制菜单配置
docker cp luci-app-tailscale-community/root/usr/share/luci/menu.d/luci-app-tailscale-community.json \
  openwrt-luci:/usr/share/luci/menu.d/
# 复制 ACL 配置
docker exec openwrt-luci mkdir -p /usr/share/rpcd/acl.d/
docker cp luci-app-tailscale-community/root/usr/share/rpcd/acl.d/luci-app-tailscale-community.json \
  openwrt-luci:/usr/share/rpcd/acl.d/
# 复制后端 ucode 文件
docker exec openwrt-luci mkdir -p /usr/share/rpcd/ucode/
docker cp luci-app-tailscale-community/root/usr/share/rpcd/ucode/tailscale.uc \
  openwrt-luci:/usr/share/rpcd/ucode/
# 创建 UCI 配置文件
docker exec openwrt-luci sh -c 'cat > /etc/config/tailscale << EOF
config settings "settings"
    option enabled "0"
    option port "41641"
    option fw_mode "nftables"
EOF'
# 重启 rpcd 以加载新插件（需要先获取 PID）
RPCD_PID=$(docker exec openwrt-luci ps | grep rpcd | awk '{print $1}')
docker exec openwrt-luci kill -9 $RPCD_PID
docker exec openwrt-luci /sbin/rpcd &
# 验证 tailscale RPC 是否已注册
docker exec openwrt-luci ubus list | grep tailscale
```
### 常见问题排查
| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `Failed to connect to ubus` | ubusd 未启动 | 先启动 `/sbin/ubusd &` |
| LuCI 显示 500 错误 `left-hand side expression is null` | procd 未启动，`ubus.call('system', 'board')` 返回 null | 启动 `/sbin/procd &` |
| 插件页面显示 RPC 错误 | rpcd 未加载 ucode 插件 | 重启 rpcd 或检查 ACL 配置 |
| 登录失败 | root 密码未设置 | `passwd root` 设置密码 |
| 主题渲染错误 | luci.themes 配置缺失 | `uci set luci.themes.Bootstrap=/luci-static/bootstrap` |
## 代码校验与格式化
- **TypeScript 检查**：`npx tsc -b`
- **ESLint 检查**：`npm run lint`
- **Prettier 格式化**：`npx prettier --write .`
- **Vitest 测试**：`npx vitest` 或 `npm test`
- **Knip 检查未使用代码**：`npx knip`
## 开发规范与建议
### 插件文件对应关系
| 本地路径 | 容器内路径 |
|----------|-----------|
| `luci-app-tailscale-community/htdocs/luci-static/resources/view/tailscale.js` | `/www/luci-static/resources/view/tailscale.js` |
| `luci-app-tailscale-community/root/usr/share/luci/menu.d/*.json` | `/usr/share/luci/menu.d/` |
| `luci-app-tailscale-community/root/usr/share/rpcd/acl.d/*.json` | `/usr/share/rpcd/acl.d/` |
| `luci-app-tailscale-community/root/usr/share/rpcd/ucode/*.uc` | `/usr/share/rpcd/ucode/` |
### 后端 ucode 调试
```bash
# 检查 ucode 语法错误
docker exec openwrt-luci ucode /usr/share/rpcd/ucode/tailscale.uc
# 重载 rpcd（需要 kill 旧进程后重启）
RPCD_PID=$(docker exec openwrt-luci ps | grep rpcd | awk '{print $1}')
docker exec openwrt-luci kill -9 $RPCD_PID
docker exec openwrt-luci /sbin/rpcd &
# 验证 RPC 方法
docker exec openwrt-luci ubus call tailscale get_status
```
### i18n 翻译同步
本地调试时不需要处理 `.po` 文件。在最终提交前，进入 luci 目录同步翻译：
```bash
cd luci
./build/i18n-sync.sh applications/luci-app-tailscale-community
```
### Playwright 浏览器访问 LuCI
```javascript
// 导航到 Tailscale 插件页面
await page.goto('http://localhost:8080/cgi-bin/luci/');
// 登录（root/password）
await page.getByRole('textbox', { name: 'Password' }).fill('password');
await page.getByRole('button', { name: 'Log in' }).click();
// 访问插件页面
await page.goto('http://localhost:8080/cgi-bin/luci/admin/services/tailscale');
// 截图
await page.screenshot({ path: 'tailscale-page.png', fullPage: true });
```
## 最后的开发建议
- **参考 LuCI 现有实现**：`openwrt/luci` 仓库中包含大量代码示例，保持一致性
- **ucode 开发参考**：LLM 对 ucode 有较多幻觉，建议参考 https://ucode.mein.io/ 和 luci 代码库
- **OpenWrt 官方文档**：遇到问题可查阅 OpenWrt 官方文档获取最佳实践
