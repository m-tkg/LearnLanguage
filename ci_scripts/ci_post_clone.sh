#!/bin/sh

# Xcode Cloud 用フック: リポジトリのクローン直後に実行される。
# このプロジェクトの LearnLanguage.xcodeproj は xcodegen の生成物（gitignore で
# 未コミット）なので、ビルド前にここで生成しておく必要がある。

set -e

echo "▸ xcodegen をインストール"
brew install xcodegen

echo "▸ LearnLanguage.xcodeproj を生成"
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
