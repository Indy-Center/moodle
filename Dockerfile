# Moodle on PHP's official Apache image, served at /moodle. Moodle has no official production image, so this
# builds one: PHP and its extensions, Moodle's release tarball, and the config in docker/.
FROM php:8.3-apache-bookworm

# The extensions Moodle requires or recommends that the base image doesn't already have.
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions exif gd intl opcache pgsql soap zip

# Upgrading Moodle is a change to these three lines. The checksum is published next to each release at
# https://download.moodle.org/download.php/direct/<branch>/moodle-<version>.tgz.sha256
ARG MOODLE_VERSION=5.2.3
ARG MOODLE_BRANCH=stable502
ARG MOODLE_SHA256=918c4bed6639056d1a3fcca37747ad95c4ec988024d2ef6b662897bcee55a581
RUN curl -fsSL -o /tmp/moodle.tgz "https://download.moodle.org/download.php/direct/${MOODLE_BRANCH}/moodle-${MOODLE_VERSION}.tgz" \
  && echo "${MOODLE_SHA256}  /tmp/moodle.tgz" | sha256sum -c - \
  && tar xzf /tmp/moodle.tgz -C /var/www \
  && rm /tmp/moodle.tgz \
  && mkdir -p /var/moodledata \
  && chown www-data:www-data /var/moodledata

COPY docker/config.php /var/www/moodle/config.php
COPY docker/php.ini /usr/local/etc/php/conf.d/moodle.ini
COPY docker/apache.conf /etc/apache2/conf-available/moodle.conf
RUN a2enconf moodle && a2enmod remoteip

COPY docker/entrypoint.sh /usr/local/bin/moodle-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/healthcheck
RUN chmod +x /usr/local/bin/moodle-entrypoint /usr/local/bin/healthcheck

ENTRYPOINT ["moodle-entrypoint"]
CMD ["apache2-foreground"]
