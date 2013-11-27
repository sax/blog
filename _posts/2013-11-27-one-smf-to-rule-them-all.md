---
layout: post
title: One SMF to Rule Them All
published: true
---

<article>
Over the past few years I've become a big fan of
[SmartOS](http://smartos.org), a distribution of
[Illumos](http://wiki.illumos.org/display/illumos/illumos+Home) built
specifically with cloud IaaS in mind. One of the features it
inherits from Solaris is the [Service Management
Facility](http://en.wikipedia.org/wiki/Service_Management_Facility),
SMF. For various reasons, SMF is my service management framework of
choice—one reason we prefer deployment on SmartOS at
[Wanelo](http://wanelo.com) is the feature-richness and stability of
daemon management under SMF.

One complaint that we had was the management of service families,
however. Recently, we started using service dependencies to help manage
groups of services, particularly in emergency situations when we need to
stop or restart many services at once.
</article>

## Some backstory

We use [Sidekiq](https://github.com/mperham/sidekiq) to process tasks
spawned from our various applications in an asynchronous manner. Sidekiq
works like Resque, except for the fact that it uses the Celluloid gem to
process multiple jobs concurrently using threads. Early on, we
discovered that this concurrency model works great for workloads that
block on I/O, such as external API calls or network calls, but that
non-blocking ruby jobs perform better with multiple processes. We use
MRI ruby, which still suffers from a global interpreter lock (GIL) on
threads and thus only runs one thread at a time. (See: [Threads in a
GIL]({% post_url 2013-11-25-threads-in-a-gil %}))

Over time as our site has grown in features and in traffic, our Sidekiq
deployment has grown more complex. Multiple groups of processes are
managed by different SMF services, each tasked with processing specific
queues. Some services are configured with higher thread counts. Others
are configured to have higher process counts. By this method, we're able
to tune multiple variables per queue. Some we want to process as quickly
as possible. Some jobs with expensive queries we allow to queue up during
high traffic spikes, knowing that they will eventually catch up without
overwhelming our databases.

Now, with ten SMF services per server controlling all of our sidekiq
jobs, what happens if we need all of them to stop at once? Let's say we
just deployed new code that includes many non-performant database
queries in our workers, and we're seeing active connections piling up on
our master databases. Let's say we've just updated a gem related to
database sharding or read/write splitting, and we just noticed that
thousands of queued jobs in different workers are about to do terrible,
terribly wrong things. Let's say that an external service used by many
of our workers just went down, and we're seeing errors spiking across
the Sidekiq cluster. We need to disable all of our sidekiq jobs, and we
need to do so now.

The first time something like this happened, I logged onto each box and
manually disabled each sidekiq SMF service, one at a time. We had a
capistrano task for this, but it had been two months since I'd had to
use it and in the heat of the moment I couldn't remember the exact
command. It seemed more expedient at the time to run forty manual
commands in a minute than to spend several minutes searching our code
base for the correct capistrano command.

## Enter SMF dependencies

After one particular meeting at Joyent, Konstantin returned with good
news. He'd talked with [Bryan Cantrill](http://dtrace.org/blogs/bmc/)
about this problem, and discovered that SMF dependencies could be used
for this purpose.

SMF allows for explicit dependency management within a configured
service. If your service needs the network stack in order to run, you
can explicitly depend on the services that manage the network stack. If
your service depends on a local install of PostgreSQL, you can
explicitly depend on postgres. If a dependency is not enabled, SMF sends
your service into the `offline` state when you try to enable it, instead
of just carrying on. It allows SMF to start processes in the proper
order on reboot, removing the possibility that processes will start out
of order and crash on an unmet dependency.

For our purposes, we created a dependency on a noop `sidekiq` service.

Our chef code looks something like this:

```ruby
service 'sidekiq' do
  supports :restart => true, :reload => true, :enable => true, :disable => true
end

smf 'sidekiq' do
  user 'deploy'
  start_command 'true'
  stop_command 'true'
  duration 'transient'
  manifest_type 'management'

  notifies :enable, 'service[sidekiq]'
end

service 'sidekiq-notifications' do
  supports :enable => true, :disable => true, :restart => true, :reload => true
end

sidekiq 'notifications' do
  user 'deploy'
  stop_timeout 200
  restart_timeout 200
  sidekiq_timeout 150
  concurrency 10
  processes 2
  queues %w(emails push_notifications)

  dependencies [
      {'name' => 'sidekiq', 'fmris' => ['svc:/wanelo/management/sidekiq'],
       'grouping' => 'require_all', 'restart_on' => 'restart', 'type' => 'service'}
  ]

  environment 'RAILS_ENV' => node['rails_env'],
              'BUNDLE_GEMFILE' => '/home/deploy/app/current/Gemfile'

  notifies :restart, "service[sidekiq-notifications]"
end
```

Now in an emergency, all we have to do on a host is run 
`svcadm disable sidekiq` and all sidekiq processes will be stopped.

If you're using Chef and Sidekiq on an Illumos- or Solaris-based system,
take a look at the cookbooks and providers we use here:

* [SMF LWRP](http://community.opscode.com/cookbooks/smf)
* [Sidekiq LWRP](http://community.opscode.com/cookbooks/sidekiq)

Many thanks to Bryan for the suggestion!
