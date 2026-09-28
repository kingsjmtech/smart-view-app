# ============================================
# Stage 1: Composer dependencies
# ============================================
FROM composer:2 AS vendor

WORKDIR /var/www/html

COPY composer.json composer.lock ./

RUN composer install \
    --no-dev \
    --no-scripts \
    --no-autoloader \
    --prefer-dist \
    --ignore-platform-reqs

# ============================================
# Stage 2: Production image
# ============================================
FROM webdevops/php-nginx:8.2

LABEL maintainer="Kingsley JM Tech"

ENV WEB_DOCUMENT_ROOT=/var/www/html/public

WORKDIR /var/www/html

# Disable ionCube loader (not used by this app)
RUN rm -f /usr/local/etc/php/conf.d/00-ioncube.ini

# Create required directories FIRST (storage/ is bind-mounted at runtime)
RUN mkdir -p \
        /var/www/html/storage/logs \
        /var/www/html/storage/framework/cache/data \
        /var/www/html/storage/framework/sessions \
        /var/www/html/storage/framework/views \
        /var/www/html/storage/app/public \
        /var/www/html/bootstrap/cache

# Copy application source
COPY . /var/www/html

# Overlay vendor from the composer stage
COPY --from=vendor /var/www/html/vendor /var/www/html/vendor

# Build the optimized autoloader and discover packages
RUN composer dump-autoload --optimize --no-dev

# public/storage → storage/app/public (storage is bind-mounted at runtime)
RUN rm -rf public/storage && ln -s /var/www/html/storage/app/public public/storage

RUN chown -R application:application /var/www/html/storage /var/www/html/bootstrap/cache && \
    chmod -R ug+rwX /var/www/html/storage /var/www/html/bootstrap/cache

EXPOSE 80

# Start supervisord (manages Nginx + PHP-FPM)
CMD ["supervisord"]
