# Release Notes

A shared fixture for the security-release marker: `search/tests/test_releases.py` reads it, and so may the shell
suites. Its newest release is 3.19.0, and its newest security release is 3.19.0. Every other `### Security` below
is one the marker rule must not count.

```markdown
## v9.9.9 (2026-01-01)
### Security
- inside a backtick fence: not a release
```

~~~~
## v9.9.8 (2026-01-01)
~~~
### Security
- inside a four-tilde fence that a three-tilde line does not close
~~~~

## v3.19.0 (2026-11-19)

The newest release, and a security release.

### Security
- A fix users must upgrade for.

## v3.18.0 (2026-11-18)

A security release, older than 3.19.0.

### Security
- An older fix.

## v3.17.1 (2026-11-18)

Not a security release: its only `### Security` heading is inside a fence.

````text
### Security
```
still inside the four-backtick fence
```
````

### Changed
- Something.

## Notes on older releases

### Security
- Under a heading that is not a release heading: it belongs to no release.

## v3.17.0 (2026-11-17)

### Fixed
- Something else.
