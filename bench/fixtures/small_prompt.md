# Small Prompt Fixture

Write a function that parses **CSV data** and returns a list of dictionaries.

## Requirements

- Handle quoted fields containing commas
- Support `\r\n` and `\n` line endings
- Skip empty lines
- First row is the header

## Constraints

- No external libraries
- Python 3.10+
- Return type: `list[dict[str, str]]`

## Example

```python
data = """name,age,city
Alice,30,"New York"
Bob,25,London"""

result = parse_csv(data)
# [{"name": "Alice", "age": "30", "city": "New York"},
#  {"name": "Bob", "age": "25", "city": "London"}]
```

## Acceptance Criteria

- [ ] Handles commas inside quoted fields
- [ ] Handles escaped quotes (`""`) inside fields
- [x] Returns empty list for empty input
- [ ] Raises `ValueError` for malformed rows

> **Note**: This is a benchmark fixture for testing editor performance.
> It exercises headers, code blocks, inline code, bold, task lists, and blockquotes.

---

*Last updated: 2026-02-18*
