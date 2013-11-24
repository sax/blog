---
layout: post
title: Today we went to the bad place…
published: true
---

<article>
You know the Bad Place. It starts with the words “How hard could it be?”
and ends with me in the shower, fully clothed under a stream of hot
water, crying. You think you’re in for a nice, quick, pleasant plane
ride, but suddenly Brian Blessed is dressed like this and waving a
pointy stick at you and you can never go home again…

<img src='{{ site.url }}/assets/images/brian-blessed-is-fucking-awesome.jpg' alt='I think this is how Brian Blessed dresses every day' />

This Bad Place involved the migration from Selenium running via Capybara
in Minitest to capybara-webkit running in RSpec. We have various reasons
for preferring this at my work, many of them subjective and based on the
collected positive experiences of several people working in this
codebase. We believe that the end result will make us happier in the
long run.

We’re not yet all the way to the other side, but I thought I would share
some learnings. Some of them were more obvious than others, but
hopefully others can learn from today’s strange coding journey.

* We will run javascript specs and unit tests in the same spec runner.
  The database cleaning configuration required to make this work and run
  quickly is non-obvious.
* Some of our testing gems have not been updated since the launch of
  this project. Some gems conflict with newer versions of other testing
  gems, blocking upgrade.
* Some of our Selenium tests do not require Javascript execution or CSS
  rendering in order to pass
* Some of our Selenium tests depend on stubbing at the server
* We over-use `Thing.any_instance.stub`
</article>

## Database Cleaner with transaction and truncation configurations

```ruby 
require 'database_cleaner'

RSpec.configure do |config|
  Capybara.javascript_driver :webkit

  config.use_transactional_fixtures = true

  config.before(:each, js: true) do
    self.use_transactional_fixtures = false
    ActiveRecord::Base.establish_connection
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
   end

  config.after(:each, js: true) do
    DatabaseCleaner.clean
    ActiveRecord::Base.establish_connection
    self.use_transactional_fixtures = true
  end
end
```

This uses RSpec’s built-in transactional test wrapping for non-js tests.
For our capybara-webkit tests, DatabaseCleaner is used with a
`:truncation` strategy. This keeps the majority of tests transactional
and fast, while allowing us to truncate before javascript tests.

We spent much longer than I’d like to admit struggling over test
failures. These failures showed up in FactoryGirl, where it would throw
confusing ActiveRecord::NotFound exceptions sometimes. Once we ensured
that ActiveRecord re-establishes its connection when switching between
cleaning strategies, everything started working!

In the long run, I’d like to add dtrace probes to ActiveRecord’s
connection management to help understand what was really happening to
cause test failures.

## Keep testing gems up-to-date

We are not on the latest version of every gem or library in our stack,
but we try to be reasonably close. Upgrading with each Rails release not
only gives us the latest security and performance patches, it makes the
incremental updates much, much easier. So why were still using a version
of Capybara over a year and a half old?

Technical debt takes many forms. In this case, we just hadn’t noticed
that we were out of date. Our tests were green, so what was the harm of
just letting things lie?

The problem is that major updates across many versions are expensive in
terms of engineer time, often requiring more effort than anyone wants to
spend. Past a certain point, major updates become intimidating. When you
know that upgrading will take you do the Bad Place, it’s tempting to
just leave it alone and hope nothing forces you to update.

At a certain point in this particular perambulation, with a few tests
failing for no explicable reason, I updated everything related to RSpec
and Capybara, removing all gems that interfered with the process. The
result? More test failures, but all deterministic, understandable and
fixable.

The lesson that I take away from this is that cheap incremental upgrades
are always preferred to major updates. This policy should be applied to
test frameworks just as aggressively (if not more so) as it is applied
to the production code.

## Selenium/Webkit tests should only cover the minimum required

One major gain that this process has given us us is a deep review of
each of our javascript tests. In several cases, we’ve found that the
tests do not require javascript or CSS to complete. While tempting to
convert them to capybara-webkit and move on, we found that it was often
faster to re-implement them as controller specs. This has many up-sides.

* Controller specs are transactional, and thus run faster
* We can stub service classes in controller specs. This allows us to
  move functionality out of controllers and into classes that we can
  unit test to death in ways that run even faster than controller specs.

This leaves capybara-webkit specs as a small set of tests that cover the
important things that unit tests won’t give us full confidence in.

## Stubbing

Somehow we were able to use stubs in our Minitest Selenium tests. I have
not yet dug into the code to determine how this worked, but it smells a
bit funny from our current vantage point. Every test where this was the
case has been easily converted into controller specs.

Getting rid of `any_instance.stub` is a little more complicated, but I
feel like the testing code smell is hiding a code smell elsewhere in the
codebase. It’s a very tempting tool to use, and I know that I will
continue to use it. In the cases I saw today, however, other code
patterns are more understandable in the long run. For instance:

```ruby
Renderer.any_instance.stubs(:view_context).returns(view_context)
expect(Story.new(user).to_s).to have_tag('a')
```

vs

```ruby
story = Story.new(user).with_view_context(view_context)
expect(story.to_s).to have_tag('a')
```

This makes it more clear that stories depend on a view_context. In the
first example, there is no relation between the two. Something happens,
and then something unrelated happens. Are they linked?

## Postscript

A major up-side was that I was pair programming with one of my Internet
heroes through this entire process. Even a journey through the Bad Place
can be fun when you’re working with an awesome pair are able to learn
from the experience!

