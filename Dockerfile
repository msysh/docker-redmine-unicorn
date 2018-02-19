FROM redmine:latest

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends build-essential \
    && echo "gem \"unicorn\"" > /usr/src/redmine/Gemfile.local \
    && bundle install --without development test \
    && apt-get purge -y --auto-remove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists

COPY res/config.ru /usr/src/redmine/config.ru
COPY res/config/unicorn.rb /usr/src/redmine/config/unicorn.rb

VOLUME /usr/src/redmine/files
VOLUME /usr/src/redmine/plugins
VOLUME /usr/src/redmine/public/themes
VOLUME /usr/src/redmine/tmp/sockets

EXPOSE 3000

COPY res/docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["unicorn"]
#CMD ["bundle", "exec", "unicorn_rails", "-D", "-p", "3000", "-c", "/usr/src/redmine/config/unicorn.rb"]
