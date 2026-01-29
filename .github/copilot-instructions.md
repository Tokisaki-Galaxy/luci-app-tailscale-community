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
    - **使用方式**：
      ```bash
      # 启动 OpenWrt 容器进行插件调试
      docker run -it --rm openwrt/rootfs:x86-64-23.05.5 /bin/ash
      
      # 挂载本地插件目录进行测试
      docker run -it --rm -v "$(pwd)/mypackage":/root/mypackage openwrt/rootfs:x86-64-23.05.5 /bin/ash
      
      # 启动带 Web 界面的 LuCI 环境 (映射到宿主机 8080 端口)
      docker run -it --rm -p 8080:80 openwrt/rootfs:x86-64-23.05.5 /bin/ash -c "
        mkdir -p /var/lock/ && opkg update && \
        opkg install luci luci-base luci-compat && \
        uci set uhttpd.main.listen_http='0.0.0.0:80' && uci commit uhttpd && \
        /etc/init.d/rpcd start && /etc/init.d/uhttpd start && \
        echo 'LuCI is ready at http://localhost:8080' && /bin/ash
      "
      ```
 - **代码校验与格式化**：
    - 环境已通过 `tsc` 类型检查和 `eslint` 代码检查。
    - **Prettier**：在提交或运行测试前，可以使用 `npx prettier --write .` 修复格式。
 - **构建与测试验证**：
    - 在完成功能开发后，运行 `npx tsc -b` 和 `npm run lint`。
    - **Vitest**：单元测试请使用 `npx vitest` 或 `npm test`。
    - **Knip**：运行 `npx knip` 自动发现未使用的文件、导出和依赖。
 - **模拟环境 (Mocking)**：
    - **MSW (Mock Service Worker)**：用于拦截网络请求。无论使用原生 JS 还是 React，都应在 `src/mocks/handlers.js` (或 .ts) 中定义模拟接口，避免硬编码。
    - **使用方式**：在入口文件中加入以下代码即可启动模拟：
      ```javascript
      if (process.env.NODE_ENV === 'development') {
        const { worker } = await import('./mocks/browser')
        worker.start()
      }
      ```

## 开发规范与建议
 - **目录结构探索**：
    - 在开始任务前，运行 `tree src -L 2` 了解模块分布。
    - 使用 `rg "TODO:|FIXME:"` 快速定位待处理事项。
   - **调试与安装插件方法**：
    - 使用 OpenWrt 容器测试/调试插件，不建议使用opkg来安装插件，编译流程太耗时并且没有任何必要。直接把插件文件复制进系统即可。例如`luci-app-tailscale-community\htdocs\luci-static\resources\view\tailscale.js`，直接复制到容器内的 `/www/luci-static/resources/view/tailscale.js` 即可；`luci-app-tailscale-community\root\usr\share\rpcd\ucode\tailscale.uc`，复制到容器内的 `/usr/share/rpcd/ucode/tailscale.uc` 即可。
    - 后端调试方法：
      - 将插件文件复制到 OpenWrt 容器内对应目录，例如 `/usr/share/rpcd/ucode/`。
      - 进行代码修改后，使用 `ucode xxxx.uc` 检查语法错误。
      - 通过 `/etc/init.d/rpcd reload` 重载 rpcd 服务应用更改。
      - 使用`ubus call rpcd listMethods`验证后端方法是否正确加载。
    - 本地调试的时候不需要管po（因为编译很麻烦），在最后提交的时候cd进luci的目录，使用`./build/i18n-sync.sh applications/luci-app-tailscale-community`来同步po文件。
    - 可通过挂载本地目录到容器内进行实时调试。
 - **解耦开发**：
    - 新功能开发优先通过单元测试 (Vitest) 或 Mock 接口 (MSW) 驱动，确保逻辑在无后端环境下可验证。
 - **代码审查准备**：
    - 提交前务必运行 `npx prettier --write .` 修复格式，并运行 `npx knip` 确保无遗留废弃代码。

## 最后的开发建议
 - openwrt/luci 仓库中包含大量现成的代码示例，建议多参考已有实现以保持一致性。
 - 遇到不确定的问题时，可查阅 OpenWrt 官方文档或 LuCI 开发指南，获取更多背景信息和最佳实践。
 - LLM模型对于ucode代码开发有较多幻觉，如果不确定可以参考`https://ucode.mein.io/`以及luci代码库获取更多帮助。
