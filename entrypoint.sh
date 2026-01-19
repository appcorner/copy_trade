#!/bin/sh

# 1. รอให้ Database พร้อมก่อน (เผื่อมันตื่นช้า)
echo "🚀 Starting CopyTradePro..."

# 2. สั่ง Migrate Database (ถ้าตารางยังไม่มี มันจะสร้างให้)
echo "📦 Running migrations..."
./bin/copy_trade eval "CopyTrade.Release.migrate"

# 3. เริ่มต้น Server
echo "⚡ Starting Server..."
./bin/copy_trade start