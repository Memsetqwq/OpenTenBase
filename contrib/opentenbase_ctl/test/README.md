# opentenbase_ctl 集成测试

`integration_single_node.sh` 在单机上验证 `opentenbase_ctl` 部署 **1 GTM + 1 CN + 1 DN** 分布式实例的完整生命周期。

## 前置条件

- 目标机器上已编译安装 OpenTenBase，并存在安装包（如 `opentenbase-5.21.8-i.x86_64.tar.gz`）；
- 目标机器上存在 `opentenbase` 系统账号，且该账号可 SSH 登录本机（口令由调用方提供）；
- `opentenbase_ctl` 已安装到可执行路径。

## 环境变量

| 变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `OTB_SSH_PASSWORD` | 是 | — | `opentenbase` 账号口令，脚本不会写入仓库 |
| `OTB_PACKAGE` | 是 | — | 安装包完整路径 |
| `OTB_CTL_BIN` | 否 | PATH 中的 `opentenbase_ctl` | 管理工具路径 |
| `OTB_INSTANCE_NAME` | 否 | `opentenbase_ctl_itest` | 测试实例名 |
| `OTB_SSH_USER` | 否 | `opentenbase` | 远程执行账号 |
| `OTB_SSH_PORT` | 否 | `22` | SSH 端口 |
| `OTB_NODE_IP` | 否 | `127.0.0.1` | 节点地址 |
| `OTB_SQL_USER` | 否 | `opentenbase` | 数据库连接用户 |
| `OTB_SQL_DB` | 否 | `postgres` | 数据库名 |
| `OTB_WORK_DIR` | 否 | `mktemp -d` | 临时工作目录 |
| `OTB_KEEP_WORKDIR` | 否 | 未设置 | 设为非空时保留临时目录 |

## 执行

```bash
export OTB_CTL_BIN=/data/opentenbase/install/opentenbase_bin_v5.0/bin/opentenbase_ctl
export OTB_PACKAGE=/data/opentenbase/install/opentenbase-5.21.8-i.x86_64.tar.gz
export OTB_SSH_PASSWORD='<opentenbase 账号口令>'
./integration_single_node.sh
```

## 断言清单

| 步骤 | 断言 |
|---|---|
| install | 输出含 `Installation completed successfully`；配置**故意省略 `conf=`**，验证该字段可选 |
| status | 输出含 `Running: 3` |
| SQL 冒烟 | CN 上 `DISTRIBUTE BY SHARD` 建表、写入 2 行、查询返回 2、删表成功 |
| stop | 输出含 `Success: 3` |
| start | 输出含 `Success: 3` |
| delete | 输出含 `Success: 3` |
| 反向用例 | SSH 口令错误时 `install` 返回码必须非 0 |

任一断言失败即以非 0 退出，并在标准错误输出打印上下文。脚本结束（无论成败）都会清理临时配置与测试实例。

## 备注

- 端口由 `opentenbase_ctl` 自动探测分配，脚本会避开已有实例占用的端口。
- 反向用例使用独立的实例名（`<实例名>_negative`），与正向用例互不干扰。