#!/usr/bin/env bash
#
# opentenbase_ctl 单机三节点（1 GTM + 1 CN + 1 DN）部署集成测试
#
# 覆盖范围：
#   1. install  —— 安装成功，且配置中省略 conf= 时仍可工作
#   2. status  —— 三个节点全部 Running
#   3. SQL 冒烟 —— CN 建表 / 写入 / 查询 / 删表
#   4. stop    —— 三个节点全部停止成功
#   5. start   —— 三个节点全部启动成功
#   6. delete  —— 三个节点全部删除成功
#   7. 反向用例 —— SSH 口令错误时 install 必须返回非 0
#
# 所有口令只从环境变量读取，脚本与仓库内均不保存任何口令。
#
# 用法：
#   export OTB_CTL_BIN=/data/opentenbase/install/opentenbase_bin_v5.0/bin/opentenbase_ctl
#   export OTB_PACKAGE=/data/opentenbase/install/opentenbase-5.21.8-i.x86_64.tar.gz
#   export OTB_SSH_PASSWORD='<opentenbase 账号口令>'
#   ./integration_single_node.sh
#
# 退出码：0 表示全部通过；非 0 表示某一步断言失败或命令异常。

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

log()  { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
fail() { printf '[%s] 断言失败：%s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 参数校验

: "${OTB_SSH_PASSWORD:?必须设置 OTB_SSH_PASSWORD（opentenbase 账号口令）}"
: "${OTB_PACKAGE:?必须设置 OTB_PACKAGE（安装包路径）}"

OTB_CTL_BIN=${OTB_CTL_BIN:-$(command -v opentenbase_ctl || true)}
[ -n "$OTB_CTL_BIN" ] || fail "找不到 opentenbase_ctl，请设置 OTB_CTL_BIN"
[ -x "$OTB_CTL_BIN" ] || fail "opentenbase_ctl 不可执行：$OTB_CTL_BIN"
[ -f "$OTB_PACKAGE" ] || fail "安装包不存在：$OTB_PACKAGE"

OTB_INSTANCE_NAME=${OTB_INSTANCE_NAME:-opentenbase_ctl_itest}
OTB_SSH_USER=${OTB_SSH_USER:-opentenbase}
OTB_SSH_PORT=${OTB_SSH_PORT:-22}
OTB_NODE_IP=${OTB_NODE_IP:-127.0.0.1}
OTB_SQL_USER=${OTB_SQL_USER:-opentenbase}
OTB_SQL_DB=${OTB_SQL_DB:-postgres}
OTB_WORK_DIR=${OTB_WORK_DIR:-$(mktemp -d)}

CONFIG="$OTB_WORK_DIR/opentenbase_config.ini"
NEG_CONFIG="$OTB_WORK_DIR/opentenbase_config_negative.ini"

cleanup() {
    if [ -x "$OTB_CTL_BIN" ] && [ -f "$NEG_CONFIG" ]; then
        "$OTB_CTL_BIN" delete -c "$NEG_CONFIG" >/dev/null 2>&1 || true
    fi
    if [ -x "$OTB_CTL_BIN" ] && [ -f "$CONFIG" ]; then
        "$OTB_CTL_BIN" delete -c "$CONFIG" >/dev/null 2>&1 || true
    fi
    if [ -z "${OTB_KEEP_WORKDIR:-}" ]; then
        rm -rf "$OTB_WORK_DIR"
    else
        log "保留工作目录：$OTB_WORK_DIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- 辅助函数

# 写出集群配置文件；口令由调用方传入，文件权限 600
write_config() {
    local file=$1 password=$2 name=$3
    umask 077
    {
        printf '%s\n' '[instance]'
        printf 'name=%s\n' "$name"
        printf '%s\n' 'type=distributed'
        printf 'package=%s\n' "$OTB_PACKAGE"
        printf '\n%s\n' '[gtm]'
        printf 'master=%s\n' "$OTB_NODE_IP"
        printf '%s\n' 'slave='
        printf '\n%s\n' '[coordinators]'
        printf 'master=%s\n' "$OTB_NODE_IP"
        printf '%s\n' 'slave='
        printf '%s\n' 'nodes-per-server=1'
        printf '\n%s\n' '[datanodes]'
        printf 'master=%s\n' "$OTB_NODE_IP"
        printf '%s\n' 'slave='
        printf '%s\n' 'nodes-per-server=1'
        printf '\n%s\n' '[server]'
        printf 'ssh-user=%s\n' "$OTB_SSH_USER"
        printf 'ssh-password=%s\n' "$password"
        printf 'ssh-port=%s\n' "$OTB_SSH_PORT"
        printf '\n%s\n' '[log]'
        printf '%s\n' 'level=INFO'
    } > "$file"
    chmod 600 "$file"
}

# 执行一条 ctl 命令，输出留在 LAST_OUTPUT，返回码留在 LAST_RC
run_ctl() {
    local desc=$1
    shift
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    LAST_OUTPUT=$out
    LAST_RC=$rc
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" >&2
        fail "$desc：命令返回非 0（rc=$rc）"
    fi
}

assert_contains() {
    local output=$1 needle=$2 desc=$3
    case "$output" in
        *"$needle"*) : ;;
        *)
            printf '%s\n' "$output" >&2
            fail "$desc：输出中未找到 '$needle'"
            ;;
    esac
}

# ---------------------------------------------------------------- 测试步骤

log "开始单机三节点集成测试（实例名：$OTB_INSTANCE_NAME）"

# 故意不写 conf=，验证该字段确实可选
write_config "$CONFIG" "$OTB_SSH_PASSWORD" "$OTB_INSTANCE_NAME"

log "步骤 1/7：安装实例"
run_ctl "安装实例" "$OTB_CTL_BIN" install -c "$CONFIG"
assert_contains "$LAST_OUTPUT" "Installation completed successfully" "安装实例"

log "步骤 2/7：查询节点状态"
run_ctl "查询状态" "$OTB_CTL_BIN" status -c "$CONFIG"
assert_contains "$LAST_OUTPUT" "Running: 3" "查询状态"

CN_PORT=$(printf '%s\n' "$LAST_OUTPUT" \
    | sed -n 's/.*PSQL connection: psql -h [^ ]* -p \([0-9][0-9]*\).*/\1/p' \
    | head -n 1)
if [ -z "$CN_PORT" ]; then
    CN_PORT=$(printf '%s\n' "$LAST_OUTPUT" \
        | sed -n 's/.*cn[0-9][0-9]*(\([0-9.]*\):\([0-9][0-9]*\)).*/\2/p' \
        | head -n 1)
fi
[ -n "$CN_PORT" ] || fail "无法从状态输出解析 CN 端口"
log "CN 端口：$CN_PORT"

log "步骤 3/7：SQL 冒烟（建表 / 写入 / 查询 / 删表）"
SQL_OUT=$(psql -h "$OTB_NODE_IP" -p "$CN_PORT" -U "$OTB_SQL_USER" -d "$OTB_SQL_DB" \
    -v ON_ERROR_STOP=1 -Atc "
        CREATE TABLE itest_tbl (id int, payload text) DISTRIBUTE BY SHARD(id);
        INSERT INTO itest_tbl VALUES (1, 'a'), (2, 'b');
        SELECT count(*) FROM itest_tbl;
        DROP TABLE itest_tbl;" 2>&1) || {
    printf '%s\n' "$SQL_OUT" >&2
    fail "SQL 冒烟执行失败"
}
assert_contains "$SQL_OUT" "2" "SQL 冒烟"

log "步骤 4/7：停止实例"
run_ctl "停止实例" "$OTB_CTL_BIN" stop -c "$CONFIG"
assert_contains "$LAST_OUTPUT" "Success: 3" "停止实例"

log "步骤 5/7：启动实例"
run_ctl "启动实例" "$OTB_CTL_BIN" start -c "$CONFIG"
assert_contains "$LAST_OUTPUT" "Success: 3" "启动实例"

log "步骤 6/7：删除实例"
run_ctl "删除实例" "$OTB_CTL_BIN" delete -c "$CONFIG"
assert_contains "$LAST_OUTPUT" "Success: 3" "删除实例"
rm -f "$CONFIG"

log "步骤 7/7：反向用例（SSH 口令错误时安装必须失败）"
NEG_NAME="${OTB_INSTANCE_NAME}_negative"
write_config "$NEG_CONFIG" "invalid-password-for-negative-case" "$NEG_NAME"
if NEG_OUT=$("$OTB_CTL_BIN" install -c "$NEG_CONFIG" 2>&1); then
    NEG_RC=0
else
    NEG_RC=$?
fi
if [ "$NEG_RC" -eq 0 ]; then
    printf '%s\n' "$NEG_OUT" >&2
    fail "反向用例：口令错误时安装仍返回 0"
fi
log "反向用例符合预期：安装返回非 0（rc=$NEG_RC）"
"$OTB_CTL_BIN" delete -c "$NEG_CONFIG" >/dev/null 2>&1 || true
rm -f "$NEG_CONFIG"

log "全部断言通过"
exit 0