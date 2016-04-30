---
layout: post
title: "Decoupling Ruby with RabbitMQ at SF.rb"
author: Eric Saxby
author_username: sax
published: true
---

<article>
On Tuesday I spoke at the [SF.rb meetup](http://www.meetup.com/sf-dot-rb/) at InstaCart HQ in San Francisco. Here are the slides that I presented from:

<script async class="speakerdeck-embed" data-id="73ef21f416d642d6a2a4d130921b72e8" data-ratio="1.77777777777778" src="//speakerdeck.com/assets/embed.js"></script>

Other great talks were from Pam Nangan about the technology gap faced by nonprofit organizations, and by Lillie Chilen on the benefits of having a well-run
internship program (and stories of good and bad experiences leading to a well-run program). This is a fantastic meetup, with a focus on diversity of speaker
backgrounds and experience. Thank you so much for having me talk!
</article>

I came away with a few notes about how my talk was received, that I will need to keep in mind for the next time I speak about this content. It seemed as if
it was well received, but it also seemed like there were two groups of listeners: people who had worked with message buses and RabbitMQ before, and
expressed that they wished they had heard this talk before they spent time learning this same material the hard way; and people who had not yet deployed
distributed systems using a message bus, and who seemed to get stuck on the specific terminology of RabbitMQ.

Notes to myself about changes for next time:

* Spend less time talking about brokers
* Spend more time (with good diagrams) to explain the conceptual differences between exchanges and queues
* Define what I mean by the words "producer" and "consumer"
* Fewer words, more diagrams
* Explain that fanout can serve in the same role, it just does not scale as well. Also explain why choosing a topic exchange is not a premature
  optimization, because of the cost of changing every usage of the message bus.

Also, I made a grave oversight during the presentation by not explicitly calling out my thanks to Matt Camuto, James Hart and Greg Poirier, whom I learned
much from during my first forays into RabbitMQ, and whom I paired with on most of the code that lead to me composing this talk. You are all the best!
