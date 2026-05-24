#!/usr/bin/env python3
"""
Supply-chain hardening: replace GIT_REPOSITORY+GIT_TAG FetchContent_Declare
with URL+URL_HASH form. Resolution date: 2026-05-24.
"""
import re, sys, os

RESOLUTION_DATE = "2026-05-24"

# ── pin table ──────────────────────────────────────────────────────────────────
PINS = [
    {
        "git_repo":    "https://github.com/catchorg/Catch2.git",
        "git_tag":     "v3.5.4",
        "commit":      "b5373dadca40b7edc8570cf9470b9b1cb1934d40",
        "url":         "https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz",
        "sha256":      "97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c",
        "desc":        "Catch2 v3.5.4",
    },
    {
        "git_repo":    "https://github.com/catchorg/Catch2.git",
        "git_tag":     "v3.5.2",
        "commit":      "05e10dfccc28c7f973727c54f850237d07d5e10f",
        "url":         "https://github.com/catchorg/Catch2/archive/05e10dfccc28c7f973727c54f850237d07d5e10f.tar.gz",
        "sha256":      "e7bbe2a99e111dfc9eb931f5e95b11b02f18f64c4f5b3aff6fdbd118fe440107",
        "desc":        "Catch2 v3.5.2",
    },
    {
        "git_repo":    "https://github.com/catchorg/Catch2.git",
        "git_tag":     "v3.7.1",
        "commit":      "fa43b77429ba76c462b1898d6cd2f2d7a9416b14",
        "url":         "https://github.com/catchorg/Catch2/archive/fa43b77429ba76c462b1898d6cd2f2d7a9416b14.tar.gz",
        "sha256":      "9ba8afe5080ae91fe6e9f079f31c86dfc69cb16b0fd62a9e58436aefe3aa511c",
        "desc":        "Catch2 v3.7.1",
    },
    {
        "git_repo":    "https://github.com/nlohmann/json.git",
        "git_tag":     "v3.11.3",
        "commit":      "9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03",
        "url":         "https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz",
        "sha256":      "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d",
        "desc":        "nlohmann/json v3.11.3",
    },
    {
        "git_repo":    "https://github.com/mborgerding/kissfft.git",
        "git_tag":     "131.1.0",
        "commit":      "8f47a67f595a6641c566087bf5277034be64f24d",
        "url":         "https://github.com/mborgerding/kissfft/archive/8f47a67f595a6641c566087bf5277034be64f24d.tar.gz",
        "sha256":      "93cfa11a344ad552472f7d93c228d55969ac586275692d73d5e7ce73a69b047f",
        "desc":        "kissfft 131.1.0",
    },
    {
        # tts_onnx used wrong v-prefix tag (v131.1.0 does not exist upstream)
        "git_repo":    "https://github.com/mborgerding/kissfft.git",
        "git_tag":     "v131.1.0",
        "commit":      "8f47a67f595a6641c566087bf5277034be64f24d",
        "url":         "https://github.com/mborgerding/kissfft/archive/8f47a67f595a6641c566087bf5277034be64f24d.tar.gz",
        "sha256":      "93cfa11a344ad552472f7d93c228d55969ac586275692d73d5e7ce73a69b047f",
        "desc":        "kissfft 131.1.0 (fixed: tag v131.1.0 does not exist upstream)",
    },
    {
        "git_repo":    "https://github.com/google/sentencepiece.git",
        "git_tag":     "v0.2.0",
        "commit":      "17d7580d6407802f85855d2cc9190634e2c95624",
        "url":         "https://github.com/google/sentencepiece/archive/17d7580d6407802f85855d2cc9190634e2c95624.tar.gz",
        "sha256":      "7710982d3b438e790646f8be623f3bbe6af1e2f2619129d1f946d4070d26bc34",
        "desc":        "sentencepiece v0.2.0",
    },
    {
        "git_repo":    "https://github.com/syoyo/safetensors-cpp.git",
        "git_tag":     "main",
        "commit":      "af90b6c3006cdcecf8b7d7254f5f32d301728acc",
        "url":         "https://github.com/syoyo/safetensors-cpp/archive/af90b6c3006cdcecf8b7d7254f5f32d301728acc.tar.gz",
        "sha256":      "7ae7a8d59560f94eb68ed09fda59abd9871fe3b0cfc5acc60506de506289aa24",
        "desc":        "safetensors-cpp (was mutable branch: main)",
    },
    {
        # rapidcheck already had a full SHA tag; add URL+URL_HASH for byte-level pin
        "git_repo":    "https://github.com/emil-e/rapidcheck.git",
        "git_tag":     "ff6af6fc683159deb51c543b065eba14dfcf329b",
        "commit":      "ff6af6fc683159deb51c543b065eba14dfcf329b",
        "url":         "https://github.com/emil-e/rapidcheck/archive/ff6af6fc683159deb51c543b065eba14dfcf329b.tar.gz",
        "sha256":      "f978132be070d6e0ae0be097c6cd5b65edeedf19f78c57158b2c43ffa412323d",
        "desc":        "rapidcheck (adding URL_HASH to existing SHA pin)",
    },
]


def build_url_block(pin, name_in_file, leading_indent, inner_indent):
    comment      = f"{leading_indent}# SHA-pinned {RESOLUTION_DATE}; {pin['desc']} → {pin['commit']}"
    block_open   = f"{leading_indent}FetchContent_Declare("
    name_line    = f"{inner_indent}{name_in_file}"
    url_line     = f"{inner_indent}URL      {pin['url']}"
    hash_line    = f"{inner_indent}URL_HASH SHA256={pin['sha256']}"
    ts_line      = f"{inner_indent}DOWNLOAD_EXTRACT_TIMESTAMP TRUE"
    block_close  = f"{leading_indent})"
    return "\n".join([comment, block_open, name_line, url_line, hash_line, ts_line, block_close])


def apply_pin(content, pin):
    """Replace FetchContent_Declare blocks for this pin. Returns (new_content, count)."""
    repo_esc = re.escape(pin["git_repo"])
    tag_esc  = re.escape(pin["git_tag"])
    count    = 0

    # ── multi-line form ───────────────────────────────────────────────────────
    pat_multi = re.compile(
        r'(?P<lead>[ \t]*)FetchContent_Declare\(\s*\n'
        r'(?P<inner>[ \t]+)(?P<name>\w+)\s*\n'
        r'(?P<body>(?:[ \t]+\S[^\n]*\n)*?)'
        r'(?P<close>[ \t]*\))\n?',
        re.MULTILINE,
    )

    def replace_multi(m):
        body = m.group("body")
        if pin["git_repo"] not in body:
            return m.group(0)
        if pin["git_tag"] not in body:
            return m.group(0)
        if "GIT_REPOSITORY" not in body:
            return m.group(0)
        nonlocal count
        count += 1
        lead  = m.group("lead")
        inner = m.group("inner")
        name  = m.group("name")
        return build_url_block(pin, name, lead, inner) + "\n"

    new_content = pat_multi.sub(replace_multi, content)

    # ── single-line form ──────────────────────────────────────────────────────
    pat_single = re.compile(
        r'(?P<lead>[ \t]*)FetchContent_Declare\('
        r'(?P<name>\w+)'
        r'(?:[^)]*?)'
        r'GIT_REPOSITORY\s+' + repo_esc +
        r'(?:[^)]*?)'
        r'GIT_TAG\s+' + tag_esc +
        r'(?:[^)]*?)'
        r'\)',
        re.DOTALL,
    )

    def replace_single(m):
        nonlocal count
        lead  = m.group("lead")
        name  = m.group("name")
        inner = lead + "    "
        count += 1
        return build_url_block(pin, name, lead, inner)

    new_content = pat_single.sub(replace_single, new_content)
    return new_content, count


def add_url_hash_if_missing(content, url_partial, sha256):
    """
    For FetchContent_Declare blocks that already have a matching URL but no URL_HASH,
    insert URL_HASH + DOWNLOAD_EXTRACT_TIMESTAMP after the URL line.
    """
    url_esc = re.escape(url_partial)

    # Match the entire FetchContent_Declare block containing this URL
    pat = re.compile(
        r'(FetchContent_Declare\([^)]*?' + url_esc + r'[^)]*?)'
        r'(\s*\))',
        re.DOTALL,
    )

    def inserter(m):
        inner = m.group(1)
        close = m.group(2)
        if "URL_HASH" in inner:
            return m.group(0)
        # Detect indent from the URL line
        url_match = re.search(r'(\n)([ \t]+)URL[ \t]', inner)
        indent = url_match.group(2) if url_match else "        "
        # Insert after the URL line (possibly multi-word)
        new_inner = re.sub(
            r'(URL[ \t]+\S+)',
            r'\1\n' + indent + 'URL_HASH SHA256=' + sha256 +
            r'\n' + indent + 'DOWNLOAD_EXTRACT_TIMESTAMP TRUE',
            inner,
            count=1,
        )
        return new_inner + close

    return pat.sub(inserter, content)


def process_file(path):
    with open(path) as f:
        original = f.read()
    content = original

    total = 0
    for pin in PINS:
        content, n = apply_pin(content, pin)
        total += n

    # Add URL_HASH to existing URL-form nlohmann/json entries that lack it
    content = add_url_hash_if_missing(
        content,
        "json/releases/download/v3.11.3/json.tar.xz",
        "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d",
    )

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        print(f"  updated: {path}  ({total} pin(s))")
        return True
    return False


def find_cmake_source_files(root):
    """Walk root, skip generated build trees."""
    BUILD_DIRS = {
        '_deps', 'build', 'build_props', 'build_fuzz', 'build_regression',
        'build_side_channel_memory_check', 'build_phase_f_clean',
    }
    result = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames
            if d not in BUILD_DIRS and not d.startswith('build_')
        ]
        for fname in filenames:
            if fname == "CMakeLists.txt":
                result.append(os.path.join(dirpath, fname))
    return result


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    files = find_cmake_source_files(root)
    changed = 0
    for f in sorted(files):
        if process_file(f):
            changed += 1
    print(f"\nDone: {changed}/{len(files)} files modified.")
