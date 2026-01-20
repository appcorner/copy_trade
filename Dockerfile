# ---------------------------------------------------
# Stage 1: Build (ใช้ Image ที่มีเครื่องมือครบเพื่อ Compile)
# ---------------------------------------------------
FROM elixir:1.16-alpine AS builder

# ตั้งค่า Environment สำหรับการ Build
ENV MIX_ENV=prod

# ลงเครื่องมือพื้นฐานที่จำเป็น
RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# 1. ลง Hex และ Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# 2. Copy ไฟล์ Config เพื่อลง Dependencies (Cash Layer)
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# 3. Copy Config ของระบบ
COPY config config

# 4. Compile Code (Dependencies)
RUN mix deps.compile

# 5. Copy โค้ดทั้งหมด
COPY lib lib
COPY priv priv
COPY assets assets

# 6. Compile Assets (Tailwind + JS)
RUN mix assets.deploy

# 7. Compile โปรแกรมหลัก
RUN mix compile

# 8. สร้าง Release (พระเอกของเรา)
# COPY rel rel
RUN mix release

# ---------------------------------------------------
# Stage 2: Runner (Image ตัวจริง เล็กและเบา)
# ---------------------------------------------------
FROM alpine:3.19 AS runner

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

# Copy ตัว Release ที่สร้างเสร็จแล้วมาจาก Stage 1
COPY --from=builder /app/_build/prod/rel/copy_trade ./

# Copy Script สำหรับรัน (เดี๋ยวเราจะสร้างไฟล์นี้กัน)
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

# ตั้งค่าให้รันได้ทุก IP
ENV PHX_SERVER=true
ENV PHX_HOST=localhost
ENV PORT=4000

# เปิด Port (Web: 4000, TCP Socket: 5001)
EXPOSE 4000
EXPOSE 5001

# สั่งรันผ่าน Script
CMD ["/app/entrypoint.sh"]