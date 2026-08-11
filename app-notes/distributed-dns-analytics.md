---
layout: appnote
title: "Designing a Distributed DNS Analytics Engine"
author: Tyler Graff
date: 2026-06-26
---

This note describes the architecture of a distributed passive DNS analytics system I helped design and build over several years. The system ingests several gigabytes per second of DNS traffic in packet form, parses it, decomposes it into atomic relational facts, stores them across time-tiered indexes, and serves historic queries spanning months of data across a sharded cluster at rates from tens to ten-thousands of queries per second depending on the complexity of the returned results.

## The Problem

DNS is arguably the most information-dense infrastructure protocol in widespread use. DNS queries and their responses encode a web of relationships: domains to IPs, domains to nameservers, CNAME chains, EDNS client subnets, and more. If these relationships are observed and stored at scale, the result is a graph that answers questions like "what IPs has this domain ever resolved to?" or "what domains have pointed at this CIDR?" or "which clients resolved this domain today?" These answers can be critical for threat detection, incident response, and network forensics.

The engineering problem is threefold: DNS traffic volume is enormous, the useful queries are relational, and extremely large result sets are needed to derive valuable insight. Traditional relational databases, document stores, and full-text search systems are a poor fit for the problem. You need a system that:

- Ingests at wire speed without dropping packets
- Decomposes each transaction into its constituent relationships
- Stores months to years of history with bounded resource growth
- Serves relational queries by the thousands across the full corpus within seconds
- Scales horizontally without operational complexity

These goals are in tension. Ingestion throughput favors simple append. Query performance favors sorted indexes. Long retention favors compression. Horizontal scale favors coordination. The architecture that follows is a set of deliberate tradeoffs across these tensions.

## The Core Abstraction: Relational Decomposition of DNS

The key design decision that enables everything downstream is the normalization of DNS traffic into flat, uniform relational tuples.

A single DNS response contains nested, variable-structure data: multiple questions, multiple answers with different record types, authority records, glue records, EDNS options, and more. Instead of storing transactions as documents, we decompose each one into its atomic relationships. A response containing an A record, two CNAME hops, and an NS delegation becomes four separate relationships, each independently indexable and mergeable.

We store these as a typed relationship with volume metadata:

```
struct {
  uint32_t first_seen;
  uint32_t last_seen;
  uint32_t count;
  uint32_t length;
  uint8_t  str[];    // the relationship key
};
```

We defined 32 relationship types covering the full DNS relational space: domain->IPv4, domain->IPv6, domain->nameserver, domain->CNAME target, stub resolvers, NX responses, and so on. Each type has a fixed-width key encoding (4 bytes for IPv4, 16 for IPv6, variable for domains) so that downstream storage can sort and binary-search without parsing.

Ingestion and decomposition happens in 600-second windows, aligned to the wall-clock hour. Within a window, duplicates are merged by incrementing the count and extending the time range. This provides natural temporal bucketing and volume reduction before data ever hits storage.

This abstraction has a powerful property: relationships from different time windows merge trivially. Take the minimum `first_seen`, maximum `last_seen`, and sum the counts. This means aggregation across hours to months is the same operation and enables a tiered storage model.

## Tiered Storage by Temperature

Data moves through three storage tiers with decreasing temperature:

**Hot tier (in-memory, 1 hour):** The current hour lives in Judy tries (sparse associative arrays with O(1) average insertion and lookup). Data is mutable, accepting new relationships in real-time while simultaneously serving queries. At hour boundary, the tier freezes, sheds maintenance overhead, and serves read-only queries until replaced.

**Warm tier (on-disk, 1 day):** Frozen hourly data gets serialized into sorted, mmap'd binary files through a multi-pass pipeline: extract strings into a deduplicated string pool, sort all relationship tables, compress counters, write the final file. Once written, queries operate directly on mmap'd memory with zero deserialization.

**Cold tier (on-disk, 1 month):** Same file format as the warm tier, but covering a 1 month timespan.

The key pragmatic design decision was to accumulate DNS relationships into tiers independently rather than by hot->warm->cold cascade. The same information is sent to hot, warm, and cold tiers, each aggregating and serializing independently. This massively simplifies system architecture and increases reliability, at the expense of only doubling storage requirements. For example, warm tier storage is discarded only once its overlapping cold-tier storage has successfully serialized. The relationship abstraction makes tier transitions trivial: it's the same data at every level, just in different locations and optimized for different access patterns.

## The On-Disk Format: Designing for mmap

A custom binary file format is where most of the performance engineering lives. Design constraints: queries must never deserialize, all access must work via pointer arithmetic on mmap'd memory, and the format must support binary search across 30+ relation types simultaneously.

The file layout:

- **512-byte header** with block offsets for each data section
- **String pool:** All variable-length strings (domains, nameservers) stored once in a compressed, deduplicated block with indexed offsets. O(1) access by index.
- **Relation tables:** Fixed-width records sorted by key. Each relation type (domain->IP, IP->domain, domain->NS, etc.) gets its own table, enabling binary search directly on the key field.
- **Cardinality estimates:** HyperLogLog structures (2048 buckets, 11-bit precision, 3 KB each) for approximate unique counts without materializing full sets.
- **Bloom filters:** For fast negative lookups before committing to a full table walk.

Counter compression uses exponential companding inspired by voice codecs. 32-bit counts are mapped into 8-bit numbers by a base-1.063 exponential scale covering 0 to 31.5 million. This gives >96% accuracy while reducing per-record storage fourfold. The tradeoff is explicit: counts above 19 are approximate by no worse than 4%. This is a favorable trade for an analytics system where "seen approximately 30,000 times" is as useful as "seen exactly 30,308 times," while preserving small-value counts that likely hold significant signal.

The result: queries against months of historical data execute as binary searches over mmap'd memory with no allocation, no parsing, and no locking. The OS page cache becomes the query cache for free.

## Distribution Model: Simple Sharding and Best-Effort Messaging

The system distributes data across a fixed 24-shard space. A domain's shard is determined by a hash of its effective second-level domain: `mail.google.com` and `drive.google.com` land in the same shard. This means queries for all subdomains of a zone hit a single shard, avoiding scatter-gather for the most compute-intensive access pattern.

Queries fan out from a client to all nodes owning the target shard across the relevant time range. Each node executes locally and returns results. The client aggregates, deduplicates, and applies limits.

The messaging layer uses a message queue transporting a compact binary encoded message (16 type codes: integers, strings, CIDR-typed values, nanosecond timestamps, nested containers). Transport is best-effort with short timeouts. If a node is slow or down, the query returns partial results rather than blocking. For an analytics workload, partial results with flagged gaps are more useful than hanging queries (but good luck convincing analysts of that!).

What we *didn't* build: shard migration, replication, or consensus. The 24-shard ceiling is fixed. Nodes are stateless enough to rebuild from ingestion streams. This limits elasticity but eliminates an entire class of distributed systems failure modes. This is the right trade for a system where data is reproducible from source captures and queries tolerate partial results.

## Real-Time Detection Layer

The same relationship stream that feeds storage also feeds a real-time anomaly detection engine. It operates in two phases:

1. **Recovery:** Ingest 24 hours of historical data to establish baseline state: what domains, IPs, nameservers, and zones are "known."
2. **Detection:** Process live stream and emit events when observations deviate from baseline.

Event types include: newly-observed TLDs, zones not seen in a configurable window, nameserver changes for tracked domains, domains pointing to new CIDRs, and DNS tunneling detection based on query entropy patterns.

The design choice here is that detection operates on the same normalized tuples as storage. No separate parsing pipeline. A new relationship type automatically becomes available to both storage queries and real-time detection without additional integration work.

## What I'd Do Differently

**No Hot Storage.** In retrospect, hot storage was vastly underutilized relative to its implementation effort and memory footprint. The real-time detection layer provided the great majority of insight into less-than-day-old data.

**Proactive Handling of Abusive Domains.** Our operations were regularly hindered by the appearance of zones with extremely high numbers of subdomains, resulting in excessive cold-storage disk footprints. This pattern is used by large-scale service providers who "abuse" DNS to encode high-cardinality information into subdomains (e.g. an ephemeral video-conference channel or a client session token). Our ingestion and sharding mechanisms could handle this only reactively, by providing a list of such "abusives" to aggressively filter. Proactive online tallying of subdomain count, using HLL for example, would have significantly decreased both operational and maintenance effort.

**Replication.** A node failure loses that shard's time window until rebuilt from source data. For our operational context this was acceptable. However, simple changes to our query protocol would enable hosting arbitrary replication of nodes and would open the door for redundancy without much complexity.

**Python API.** Our system provided a command-line query utility with the ability to pass queries via arguments or in bulk via stdin, and receive results via stdout. Our consumers favored using Python for their data science tasks. We should have prioritized closing this gap early on in the development process.