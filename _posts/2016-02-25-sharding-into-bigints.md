---
layout: post
title: "Sharding into big integers"
author: Eric Saxby
author_username: sax
published: false
---

One day you wake up, you grab your laptop, you open your email, you see a strange alert, and you open up your exception tracking service. There you see the following text.

```
ActiveRecord::StatementInvalid: PG::NumericValueOutOfRange: ERROR: integer out of range
```

You then close your laptop and climb back into bed. If anyone asks later, you never saw that message. What even is computer?

## Id generation in Rails

By default when Rails migrations create id columns in Postgres, it uses the `serial primary field` native type, an `integer`. When reference columns are specified, Rails uses an `integer`. The range of numbers covered by the integer numeric type in Postgres is:

```
-2147483648 to +2147483647
```

The range of numbers for bigints is:

```
-9223372036854775808 to 9223372036854775807
```

For most datasets, integers are more than enough for the id space of most tables. In the lifetime of a company, the upper bound of integers might never be reached in any database. Unfortunately (or fortunately), we have run into this problem several times now. The first was caused by a bug, where data synchronized between two of our applications unintentionally deleted and recreated the data on a daily basis. A moderate-sized dataset of a few hundred million rows had overflowed the integer space of its ids. Whoops!

This turned out to be a very insidious and unexpected bug, which was particularly interesting to me because of where we have **not** run into integer overflows in the past. We have services with more than three billion records in a single table space. In those applications we have sharded the data heavily, using thousands of Postgres schemas as logical shards across a set of database zones. Because of the nature of that data, however, we were able to generate unique identifiers for each row based on the data in the row, in the form of base62 encoded strings. Doing so allowed us to shard data without having to worry about unique identifier generation—as a side effect, it completely obviated the possibility of integer overflow errors.

The second case where we have had to migrate from integers to bigints was another scalability project. In order to scale writes to one of our internal Rails applications, we decided to split the entire database into multiple shards. The upside was that this was quite easy to do using the Multidb gem; Multidb does not natively do everything we need, but the code is extremely simple, readable, and the missing bits were easy for us to fill in ourselves. The downside was that in order to do this sharding, we needed to generate unique ids across shards.

## Multidb

I won't spend much time discussing the changes needed to fill in the gaps with Multidb. Suffice it to say that we needed to do some work to ensure that queries are thread safe, and we needed to ensure that migrations run on all shards. This latter part is slightly more tricky than one might think, as it needs to not only support new migrations, but it needs to support running all old migrations on a new shard.

<script src="https://gist.github.com/sax/1dcaacab2b0068f132a8.js"></script>

Our `database.yml` looks something like this:

```yaml
common: &common
  adapter: postgresql
  host: 127.0.0.1
  port: 5432
  username: *******
  password: *******
  encoding: unicode
  pool: 20
  min_messages: WARNING
  schema_search_path: public
  multidb:
    fallback: false
    databases:
      stuff:
        schema_search_path: stuff
      things:
        schema_search_path: things

development: &dev
  <<: *common
  database: development

test: &test
  <<: *common
  database: test
```

## Distributed id generation

We have evaluated two major solutions for generating unique identifiers in a sharded application. The first, Snowflake, is a technology developed by Twitter. There is a major problem with many technologies open sourced by Twitter, however—they often to have open-source and closed-source versions, with the open code months or years behind the private repositories. There are exceptions to this rule (thank you Manju!), but unfortunately Snowflake is not one of them (at the time of this writing). Another issue is that, even if we were to accept the age of the codebase (and anecdotal knowledge of closed-source bug fixes that we’d be missing), or were able to find or develop a Snowflake alternative (at the time of writing, no open-source Snowflake alternatives claim to be production-ready), choosing Snowflake adds a complicated distributed dependency to our application.

The second solution we identified was developed by Instagram, and uses Postgres itself to generate unique identifiers with plsql functions. As we already use and depend on Postgres, we felt that this was a better fit for our use case. It can be found at http://instagram-engineering.tumblr.com/post/10853187575/sharding-ids-at-instagram.

...

The plsql functions we used to generate unique identifiers are very slightly different from the code presented by Instagram in their blog post:

```sql
execute <<-EOSQL

CREATE SEQUENCE #{schema}.id_generator_seq;

CREATE OR REPLACE FUNCTION #{schema}.current_shard_id(OUT result int) AS $$
BEGIN
  result := #{shard_id};
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION #{schema}.id_generator(OUT result bigint) AS $$
DECLARE
    our_epoch bigint := 1433806952013;
    seq_id bigint;
    now_millis bigint;
    shard_id int;
BEGIN
    SELECT #{schema}.current_shard_id() into shard_id;
    SELECT nextval('#{schema}.id_generator_seq') % 1024 INTO seq_id;

    SELECT FLOOR(EXTRACT(EPOCH FROM clock_timestamp()) * 1000) INTO now_millis;
    result := (now_millis - our_epoch) << 23;
    result := result | (shard_id << 10);
    result := result | (seq_id);
END;
$$ LANGUAGE PLPGSQL;

EOSQL
```

When we run cross-shard migrations, we iterate through every available Multidb connection, where we set the `schema_search_path`. With this information, we can look up manual configuration from a settings file:

```ruby
## Settings
#  shards:
#    default:
#      schema: public
#      shard_id: 0
#    other_shard:
#      schema: shard1
#      shard_id: 1
schema = ActiveRecord::Base.connection.instance_variable_get(:@config)[:schema_search_path]
shard_entry = Settings.shards.values.find { |v| v['schema'] == schema }
shard_id = shard_entry['shard_id']
```

The specific ways in which this is different from the Instagram examples are as follows:

* We use a pl/pgsql function to determine what shard number to use for each shard, rather than hard coding it into the main function. This is purely for aesthetic reasons.
* We use a more recent epoch

The other bits are the same. Specifically, the `id_generator` function returns an 8 byte integer. These 64 bits are arranged as follows:

* 41 bits — millisecond interval since epoch
* 13 bits — the id of the current shard
* 10 bits — mod 1024 of a Postgres sequence in the current shard’s schema

The last 10 bits allow us to generate 1024 unique identifiers in any individual millisecond. Because of the CPU resources allocated to the application, we know that there will never be more that 1024 records created in a single millisecond per table. If and when the scale of the data in the application increases to the the point where this becomes a problem, we can increase the number of shards.

There are a number of nice things about this algorithm. First of all, we can define our starting epoch such that the first id generated by the function is outside of the range of 4 byte integers. This means that any 4 byte integer we see is easily identified as belonging to shard 0. Doing so allows us to roll out the sharding code with a single shard, and then add new shards in the future. The application becomes “sharded,” where the total shard count is 1—the public schema of the old database. It also allows us to deploy all code changes without regenerating ids for old rows. Once in production, we can continue our incremental development by adding a second shard.

Another nice thing about this is that the shard is “baked” into the id value itself. Given an id, we can do very simple bit logic to look up the shard.

Other lookups are less ideal, but we can still do cross-shard queries and use an object cache to reduce the cost of subsequence requests.

The worst thing about this algorithm is that it requires id columns to be 8 byte integers; when we rolled this out, our application already had hundreds of millions of records with 4 byte integers ids. Every table needed to be changed, requiring every record to be rewritten. More on that later.

## Automatic bigints

When creating new tables, we don’t want to have to remember to use bigints in migrations. Fortunately for us, a very simple monkey patch solves the problem.

```ruby
# https://gist.github.com/sax/cc6ebf1805e732112134
require 'active_record/connection_adapters/postgresql_adapter'

module ActiveRecord
  module ConnectionAdapters
    class TableDefinition
      def references(*args)
        options = args.extract_options!
        polymorphic = options.delete(:polymorphic)
        index_options = options.delete(:index)
        args.each do |col|
          column("#{col}_id", :bigint, options)
          column("#{col}_type", :string, polymorphic.is_a?(Hash) ? polymorphic : options) if polymorphic
          index(polymorphic ? %w(id type).map { |t| "#{col}_#{t}" } : "#{col}_id", index_options.is_a?(Hash) ? index_options : {}) if index_options
        end
      end
    end

    class PostgreSQLAdapter < AbstractAdapter
      NATIVE_DATABASE_TYPES[:primary_key] = ‘bigserial primary key'
    end
  end
end
```

We were able to make this change immediately, since it could't hurt anything. It also allowed us to verify in development environments that nothing would break. After we had migrated the data and were ready to roll out the sharding code, the last monkey patch changed to `bigint default id_generator() not null primary key`.

## The naive migration attempt

We as operators of the project were fortunate in that we were able to accept long periods of downtime. This application is not directly customer-facing, although long outages have a cascading effect on important business metrics. With that in mind, we decided to try a very simple approach to migrating this data.

```ruby
change_column :products, :id, :bigint
```

Repeat times N, where N is the number of tables in the system. But wait, what about associated records?

```ruby
change_column :variants, :product_id, :bigint
```

We had some more work to do on the sharding code, so we committed these migrations and tried to deploy.

Nope! A short time later we checked our console and discovered that it had failed. The queries had timed out in the first column alteration. Well… no real problem there. Since ActiveRecord grabs a single database connection on its first query, then holds onto that connection for the duration of its execution, we can add a simple solution at the beginning of the `#up` method.

```ruby
execute ‘set statement_timeout=0'
```

So… commit and push that and deploy! Problem solved.

Four hours later, after solving the problem of how to run cross-shard database migrations, we checked back in on the status of the data migration. It had gotten through three columns, in some of the smaller tables. We had no idea how long the full migration was going to take, but it was going to take days, if it succeeded at all.

A few `pg_terminate_backend` calls later, we were back to square one, but the application was running again.

The naive approach was a failure, but on the plus side we had not wasted very much time. The migrations themselves had taken less than five minutes to write, and we’d spent less than half an hour manually running them and checking in on their progress.

## Foreign keys

Taking a closer look at what was going, we found a glaring problem with our migration strategy. Not only do we have a lot of indices, we have foreign key constraints in this database. Every row update requires an update to each index on the effected table. Every update that effects a foreign key requires a lookup of the associated row.

So at the very least, let’s drop all foreign keys and then retry our naive migration approach. This was quick to do and deploy. Back to sharding!

...

Checking back in a while later and doing some quick maths, we realized that this was still going to take days to run.

## The real approach

Doing some searching on the internets led us to a blog post by Hubert Lubaczewski from 2009:  http://www.depesz.com/2009/09/19/speeding-up-dumprestore-process/. In this post he talks about speeding up the process by which he did a major upgrade of Postgres. While a lot has changed in Postgres since then, everything in his post struck major chords with us. Even though pg_dump allows for parallelism as of Postgres 9.3, disproportionate table sizes limit the maximum concurrency that we can benefit from—each table can only be exported by a single core at a time. The database in question for us has a small number of tables with tens to hundreds of millions of records, and a large number of tables with thousands to hundreds of thousands of records.

One thing that we noticed when trying to apply Depesz’s solution to our problem was that pg_dump allows for dumping schemas separate from data. It also allows for indices to be dumped separately from table structure and sequences. A workflow started to develop:

* Stop the application to ensure that no data changes
* Dump the table structure and sequences to a `structure.sql` file
* Dump the indices to a `indices.sql` file
* Dump the data using xargs with psql to run Postgres’ COPY TO FILE with massive concurrency
* Rename the current schema, `public` to `public_backup` to allow us to quickly recover from mistakes
* Create a new `public` schema
* Change the `structure.sql` file to change all `integer` id and reference columns to `bigint`
* Import the table structure and sequences
* Import the data using find piped to xargs with massive concurrency
* Recreate primary key indices with concurrency equal to number of tables
* Recreate `CREATE INDEX` indices with parallelism equal to the number of indices
* Recreate foreign keys with parallelism equal to number of tables

With parallelism equal to 1.5 times the number of available cores in the database system, we were able to export all of the data in 12 minutes. After several false starts and fixes, we were able to get the data import down to 18 minutes. Recreating the primary keys and adding back in the non-foreign key indices took around 40 minutes. Unfortunately I was not able to get a timeline of reimporting the foreign key constraints, but the speed of the other steps allowed for a huge window in which to run the last step. This application can tolerate downtimes of multiple hours.

## Surprises

Our biggest surprise on this project was the fact that it was possible to do so with so little Ruby code, but so much pain to convert all of our data. Naively, we thought that this would be reversed.

The only major code surprise was that links in several views broke for records created after we switched id generation mechanisms. By "broke," I mean that we discovered several weeks later that links would go to incorrect pages, or to 404 error pages. This was incredibly awkward, as at first sight it looked as if our sharding code might be completely borked, causing massive data inconsistencies. When we looked closer, however, we found that in every case where we accessed records in Ruby, the data was correct. It was only when rendering views with Javascript that we faced problems. It turns out that Javascript represents all numbers as floats, and that in the bigint number space there are float imprecision errors... bigints values will convert into nearby different values. This can be solved by always passing bigints as strings to Javascript views.

Oh, and when you pass bigints to NewRelic, their code suffers from the same float imprecision errors. Whoops!
