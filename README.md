## livinginthepast.org

**Archived in favor of [litp.org](https://github.com/livinginthepast/litp.org)**

This is the blog for livinginthepast.org. It is built using jekyll and
compass.

## Development

```bash
bundle exec jekyll serve
```

Changes will require the server to be restarted.

## Deployment

Deployment credentials are not checked into the repository (for various
reasons, including the desire to keep it a public repo).

```bash
bundle exec compass compile
bundle exec jekyll build
```

Configure `s3_website` using `s3_website.yml`

```bash
s3_website push
```
