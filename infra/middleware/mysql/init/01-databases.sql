-- 业务三库：user / video / interaction 各自独立，服务只连接自己的库。
-- 表结构由各服务启动时的 AutoMigrate 创建，这里只负责建库。
CREATE DATABASE IF NOT EXISTS feed_user
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS feed_video
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS feed_interaction
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 业务账号 phx 由 chart 的 auth.username / auth.password 创建，
-- 这里只补齐另外两库的授权，避免密码在 SQL 里出现第二份真值。
GRANT ALL PRIVILEGES ON feed_user.* TO 'phx'@'%';
GRANT ALL PRIVILEGES ON feed_video.* TO 'phx'@'%';
GRANT ALL PRIVILEGES ON feed_interaction.* TO 'phx'@'%';
FLUSH PRIVILEGES;
