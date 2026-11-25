#!/bin/zsh
# 运行测试，参数原样传给 swift test。用法：
#   ./scripts/test.sh
#   ./scripts/test.sh --filter LLMTaskTests
#
# 只装了 CommandLineTools 时（Swift 6.4，Swift Build），测试 target 的编译有时会随机报
# “plugin for module 'TestingMacros' not found”：依赖扫描算出的宏插件里少了 Swift Testing 的，
# 和代码无关，过一会儿再编又好了。碰到这个错误时清掉测试 target 的中间产物再试，最多 5 次；
# 其他编译错误和测试失败照常报出。
# 旧的构建系统（--build-system native）在这个环境下找不到 Testing 模块，换不了。
set -uo pipefail
cd "$(dirname "$0")/.."

tests_build=.build/out/Intermediates.noindex/PPTReader.build/Debug/PPTReaderTests-p.build
for attempt in 1 2 3 4 5; do
    output=$(swift test "$@" 2>&1)
    code=$?
    if [[ $code -eq 0 || $output != *"plugin for module 'TestingMacros' not found"* ]]; then
        print -r -- "$output"
        exit $code
    fi
    print -u2 "（第 $attempt 次编译没找到 Swift Testing 的宏插件，清掉测试的中间产物后重试）"
    rm -rf "$tests_build"
done
print -r -- "$output"
exit $code
