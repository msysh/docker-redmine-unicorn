# config/unicorn.rb

rails_root = File.expand_path(".")

worker_processes 2

user "redmine", "redmine"

working_directory rails_root

if ENV.key?('UNICORN_LISTEN_PORT') and ENV['UNICORN_LISTEN_PORT'] =~ /^[0-9]+$/
  p "Listen: #{ENV['UNICORN_LISTEN_PORT']}"
  listen ENV['UNICORN_LISTEN_PORT']
else
  ENV['UNICORN_LISTEN_PORT'] = ''
  listen File.expand_path('tmp/sockets/unicorn.sock', rails_root), :backlog => 1024
end

pid File.expand_path('tmp/pids/unicorn.pid', rails_root)

stderr_path File.expand_path('log/unicorn.stderr.log', rails_root)

stdout_path File.expand_path('log/unicorn.stdout.log', rails_root)

preload_app true

timeout 30

if GC.respond_to?(:copy_on_write_friendly=)
  GC.copy_on_write_friendly = true
end

before_fork do |server, worker|
  defined?(ActiveRecord::Base) and ActiveRecord::Base.connection.disconnect!

  old_pid = "#{server.config[:pid]}.oldbin"
  if old_pid != server.pid
    begin
      sig = (worker.nr + 1) >= server.worker_processes ? :QUIT : :TTOU
      Process.kill(sig, File.read(old_pid).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
    end
  end
  sleep 1
end

after_fork do |server, worker|
  defined?(ActiveRecord::Base) and ActiveRecord::Base.establish_connection
end
