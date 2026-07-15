#!/bin/bash
# Training App dev flow — subcommands: test | build | install | deploy | selftest
set -e

# 路径自动推导：脚本位于 <SPM>/Training/dev_flow.sh
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPM="$(cd "$PROJECT/.." && pwd)"
BUNDLE="${TRAINING_BUNDLE_ID:-com.example.Training}"

# 设备 UDID 通过环境变量提供，不硬编码到仓库：
#   export TRAINING_UDID=<你的默认设备 UDID>
#   export TRAINING_UDID_ALT=<备用设备 UDID>   （可选）
# 用法：
#   --device alt       → 使用 TRAINING_UDID_ALT
#   --device <udid>    → 直接指定 UDID
#   不指定              → 使用 TRAINING_UDID
DEVICE=""
UDID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        *) break ;;
    esac
done
case "$DEVICE" in
    alt)      UDID="${TRAINING_UDID_ALT:?请先设置环境变量 TRAINING_UDID_ALT}" ;;
    "")       UDID="${TRAINING_UDID:?请先设置环境变量 TRAINING_UDID}" ;;
    *)        UDID="$DEVICE" ;;
esac

run_test() {
    echo "【测试执行结果】"
    cd "$SPM"
    local output
    output=$(swift test 2>&1)
    echo "$output" | grep -E "✘|✔.*passed|✔.*failed|test run" || true
    if echo "$output" | grep -q "✘"; then
        echo "测试失败，终止流程"
        exit 1
    fi
    echo "测试通过"
}

run_build() {
    echo "【Build编译日志】"
    cd "$PROJECT"
    # 注入版本标记到 AppVersion.swift（git hash + 源码指纹 + 时间），build 后恢复 unset。
    local VER_FILE="Training/AppVersion.swift"
    local GIT_HASH
    GIT_HASH=$(cd "$SPM" && git rev-parse --short HEAD 2>/dev/null || echo "nogit")
    # 源码指纹：关键 .swift 文件的 git blob hash 求和（内容 hash，不依赖 mtime）。
    # 反映工作区真实内容状态。clean build 强制重编译，指纹校验是双保险。
    local SRC_FINGERPRINT
    SRC_FINGERPRINT=$(cd "$SPM" && git ls-files -s 'Training/Training/**/*.swift' 'Training/Training/*.swift' 2>/dev/null | md5 | cut -c1-8)
    [ -z "$SRC_FINGERPRINT" ] && SRC_FINGERPRINT=$(find "$SPM/Training/Training" -name "*.swift" -exec shasum {} \; 2>/dev/null | sort | md5 | cut -c1-8)
    local BUILD_TIME
    BUILD_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    # 备份并注入
    cp "$VER_FILE" "$VER_FILE.bak"
    sed -e "s/static let buildHash: String = \"unset\"/static let buildHash: String = \"$GIT_HASH\"/" \
        -e "s/static let buildTime: String = \"unset\"/static let buildTime: String = \"$BUILD_TIME\"/" \
        -e "s/static let srcFingerprint: String = \"unset\"/static let srcFingerprint: String = \"$SRC_FINGERPRINT\"/" \
        "$VER_FILE.bak" > "$VER_FILE"

    # CLEAN_BUILD=1 强制 clean，杜绝增量编译缓存导致装旧二进制（基建铁律：装的必须=当前代码）。
    local CLEAN_FLAG=""
    if [ "${CLEAN_BUILD:-1}" = "1" ]; then
        CLEAN_FLAG="clean"
    fi
    if xcodebuild -project Training.xcodeproj -scheme Training -destination "platform=iOS,id=$UDID" -allowProvisioningUpdates $CLEAN_FLAG build 2>&1 | grep -q "BUILD SUCCEEDED"; then
        mv "$VER_FILE.bak" "$VER_FILE"
        # 记录本次 build 的指纹到 marker，verify 读它对比设备（不重算，避免 mtime 漂移）。
        echo "hash=$GIT_HASH fp=$SRC_FINGERPRINT time=$BUILD_TIME" > /tmp/training_build_marker.txt
        echo "BUILD SUCCEEDED (hash=$GIT_HASH fp=$SRC_FINGERPRINT clean=${CLEAN_FLAG:+yes})"
    else
        mv "$VER_FILE.bak" "$VER_FILE"
        echo "BUILD FAILED — 终止流程"
        exit 1
    fi
}

# 确认设备上 App 的版本 = 本次 build 的标记。读 /tmp marker 对比设备，不重算（避免 mtime 漂移）。
verify_version() {
    local MARKER="/tmp/training_build_marker.txt"
    if [ ! -f "$MARKER" ]; then
        echo "⚠️ 版本确认失败：找不到 build marker（先 run_build）"
        return 1
    fi
    local EXPECTED_HASH EXPECTED_FP
    EXPECTED_HASH=$(grep -o 'hash=[^ ]*' "$MARKER" | cut -d= -f2)
    EXPECTED_FP=$(grep -o 'fp=[^ ]*' "$MARKER" | cut -d= -f2)
    xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    sleep 3
    local ART="/tmp/training_version_check"
    mkdir -p "$ART"
    rm -f "$ART/version.txt"
    xcrun devicectl device copy from --device "$UDID" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source "Documents/version.txt" --destination "$ART/version.txt" 2>/dev/null | grep -qi received
    if [ ! -s "$ART/version.txt" ]; then
        echo "⚠️ 版本确认失败：拉不到 version.txt（App 可能没启动或没写标记）"
        return 1
    fi
    local DEVICE_HASH DEVICE_FP
    DEVICE_HASH=$(grep "buildHash=" "$ART/version.txt" | cut -d= -f2)
    DEVICE_FP=$(grep "srcFingerprint=" "$ART/version.txt" | cut -d= -f2)
    local OK=0
    if [ "$DEVICE_HASH" != "$EXPECTED_HASH" ]; then
        echo "❌ git hash 不一致：设备=$DEVICE_HASH build=$EXPECTED_HASH"
        OK=1
    fi
    if [ "$DEVICE_FP" != "$EXPECTED_FP" ]; then
        echo "❌ 源码指纹不一致：设备=$DEVICE_FP build=$EXPECTED_FP（二进制未含最新代码，需 clean rebuild）"
        OK=1
    fi
    if [ "$OK" = "0" ]; then
        echo "✅ 版本确认：hash=$DEVICE_HASH fp=$DEVICE_FP = 本次 build"
        return 0
    fi
    return 1
}

run_install() {
    echo "【Install安装日志】"
    # 先 build：禁止装旧版本。install 必须基于当前代码的新构建。
    run_build
    local APP
    APP=$(find "$HOME"/Library/Developer/Xcode/DerivedData/Training-*/Build/Products/Debug-iphoneos/Training.app -maxdepth 0 2>/dev/null | head -1)
    if [ -z "$APP" ]; then
        echo "找不到 Training.app，build 失败"
        exit 1
    fi
    # 时间戳校验：产物必须是刚 build 的（10 分钟内），否则拒绝装旧版
    local age
    age=$(( $(date +%s) - $(stat -f %m "$APP") ))
    if [ "$age" -gt 600 ]; then
        echo "❌ 拒绝安装：Training.app 产出于 ${age}s 前（>600s），疑似旧版本。请重新 build。"
        exit 1
    fi
    xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | grep "App"
    # 装完必须确认版本 = 当前源码，防止装旧版。失败则报警。
    verify_version
}

run_selftest() {
    echo "=== 自测模式 (XCUITest) ==="
    local RESULT_DIR="$SPM/artifacts/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$RESULT_DIR"
    echo "Artifacts: $RESULT_DIR"

    echo "[1/3] XCUITest 运行 16 个自测场景..."
    cd "$PROJECT"
    xcodebuild test \
        -project Training.xcodeproj \
        -scheme Training \
        -destination "platform=iOS,id=$UDID" \
        -only-testing:TrainingUITests/TrainingUITests \
        -allowProvisioningUpdates \
        -resultBundlePath "$RESULT_DIR/result.xcresult" \
        2>&1 | grep -E "Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" || true

    echo "[2/3] 拉取自测日志..."
    for i in {0..15}; do
        xcrun devicectl device copy from \
            --device "$UDID" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" \
            --source "Documents/selftest-${i}.log" \
            --destination "$RESULT_DIR/selftest-${i}.log" \
            2>/dev/null | grep -v "Enabling\|Acquired\|File received" || true
    done
    cat "$RESULT_DIR"/selftest-*.log > "$RESULT_DIR/selftest.log" 2>/dev/null || true

    xcrun devicectl device copy from \
        --device "$UDID" \
        --domain-type systemCrashLogs \
        --source . \
        --destination "$RESULT_DIR/crash" \
        2>&1 | grep -v "Enabling\|Acquired\|File received" || true

    echo "[3/3] 生成报告..."
    generate_report "$RESULT_DIR"
    echo "================================================"
    cat "$RESULT_DIR/selftest.log" 2>/dev/null
    echo "================================================"
    echo "产物: $RESULT_DIR"
    echo "报告: $RESULT_DIR/report.md"
}

generate_report() {
    local DIR="$1"
    local DATE=$(date "+%Y-%m-%d %H:%M")
    local names=("恢复查询" "训练计划" "睡眠分析" "记录运动 1" "记录运动 2" \
      "综合查询" "单日数据" "比赛工具" "比赛注入" "昨天比赛表现" \
      "今天状态" "今天0点至今" "查昨天RHR" "查前天RHR" "7天RHR表" "赛后恢复")

    local REPORT="$DIR/report.md"

    cat > "$REPORT" << EOF
# 自测报告 — $DATE

## 概览

| # | 场景 | 结果 |
|---|------|------|
EOF

    for i in {0..15}; do
        local status="❌ (未完成)"
        [ -f "$DIR/selftest-$i.log" ] && status="✅"
        echo "| $((i+1)) | ${names[$i]} | $status |" >> "$REPORT"
    done

    echo "" >> "$REPORT"
    echo "## 场景详情" >> "$REPORT"

    for i in {0..15}; do
        local logfile="$DIR/selftest-$i.log"
        if [ -f "$logfile" ]; then
            echo "" >> "$REPORT"
            echo "### $((i+1)). ${names[$i]}" >> "$REPORT"
            echo "" >> "$REPORT"
            echo "\`\`\`" >> "$REPORT"
            cat "$logfile" >> "$REPORT"
            echo "\`\`\`" >> "$REPORT"
        fi
    done

    local failed
    failed=$(find "$DIR" -maxdepth 1 -name "selftest-*.log" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$failed" -lt 16 ]; then
        echo "" >> "$REPORT"
        echo "## 失败分析" >> "$REPORT"
        echo "以下场景未在超时时间内完成：" >> "$REPORT"
        for i in {0..15}; do
            if [ ! -f "$DIR/selftest-$i.log" ]; then
                echo "- **${names[$i]}**：未检测到 SELFTEST_DONE（超时或崩溃）" >> "$REPORT"
            fi
        done
    else
        echo "" >> "$REPORT"
        echo "## 全部通过 ✅" >> "$REPORT"
    fi
}

case "${1:-}" in
    test)     run_test ;;
    build)    run_build ;;
    install)  run_install ;;
    verify)   verify_version ;;
    deploy)   run_test && run_build && run_install ;;
    selftest) run_test && run_selftest ;;
    *)        echo "用法: $0 [--device alt|<UDID>] {test|build|install|verify|deploy|selftest}" ; exit 1 ;;
esac
