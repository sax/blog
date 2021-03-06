---
layout: post
title: Threads in a GIL
published: true
---

<article>
MRI Ruby has a [global interpreter
lock](http://en.wikipedia.org/wiki/Global_Interpreter_Lock) (GIL),
meaning that even when writing multi-threaded Ruby only a single thread
can be on-CPU at any given point in time. Other distributions of Ruby
have done away with the GIL, but even in MRI threads can be useful. The
Sidekiq background worker gem takes advantage of this, running multiple
workers in separate threads within a single process.

If the workload of a job blocks on I/O, Ruby can context-switch to other 
threads and do other work until the I/O finishes. This could happen when 
the workload reaches out to an external API, shells out to another command, 
or is accessing the file system. Depending on how a job is written, writes 
to external storage like an NFS server could block on I/O.

If the workload of a process does not block on I/O, it will not benefit 
from thread switching under a GIL, as it will be, instead, CPU-bound. In 
this case, multiple processes will be more efficient, and will be able to 
take better advantage of multi-core systems.

So… why not skip threads and just deal with processes? A number of
reasons.
</article>

## Memory allocation
Threads are more memory efficient. Fewer processes means less virtual
memory allocation, allowing for more workers on fewer hosts. This can
result in considerably less cost over the course of a year. Garbage
collection fixes in Ruby 2 promise better shared memory management
between forked processes, though I have yet to see this have a material
effect in production.

## Context switching
Context switching between processes is more expensive than context
switching between threads. This is because process context switching
involves switching out the entire memory address space. Thread switching
happens within the same address space.

In Solaris it is relatively easy to set CPU affinity for processes, so
that as they switch on and off CPU they're more likely to benefit from
CPU caches. In practice we've never had to do this.

## Connection management and blocking I/O
Even when pooling database connections through a connection manager like
PGBouncer, more processes means more idle connections, and if you're not
careful (i.e. you don't monitor connection count) it's easy to
accidentally max out your database connection limit. We are particularly
aggressive about monitoring and managing active connections to
PostgreSQL, having burned ourselves a few times. When working with
multiple threads that block on I/O, we sometimes go so far as to force
ActiveRecord to release connections back into its connection pool before
starting long, blocking requests.

For instance:

```ruby
class PushNotificationWorker < WaneloWorker
  def perform!(user_id, message)
    user = User.find(user_id)
    ActiveRecord::Base.clear_active_connections!
    
    PushNotification.new(user, message).deliver!
  end
end
```

This way other threads are able to reuse the connection, even before the
first thread finishes.

## Sleepy actors
Sometimes a workload will purposefully block, for instance in a daemon
process that only wakes up every N seconds to do work. The 
[spanx](https://github.com/wanelo/spanx) gem works this way, with multiple
actors in separate threads. 

It's much easier to manage a single process daemon, from an operational point of
view, than a set of daemons. In SmartOS this means that the SMF definition for
the service does not have to manage multiple processes. Additionally this
prevents a situation where one actor may not start, which might happen with
multi-process design. It's much less confusing to type "svcadm disable
spanx-watcher" when there's a problem, than to track down four separate services
in order to stop them all.

