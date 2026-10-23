# Command processing — Sequence Diagrams (proposal)

## 1. Online accepted

```mermaid
sequenceDiagram
    participant U as User / Flutter
    participant H as Host Command API
    participant D as PostgreSQL
    participant O as Outbox Worker
    U->>H: CommandEnvelope + Auth
    H->>H: Identity/Policy/Schema checks
    H->>D: BEGIN + claim (tenant, commandId)
    D-->>H: New command or prior receipt
    H->>D: Lock + validate + write domain state, receipt, outbox
    H->>D: COMMIT
    H-->>U: ACCEPTED receipt
    O->>D: Read committed outbox
    O-->>U: Later delta via sync channel
```

## 2. Offline operation followed by Host acceptance

```mermaid
sequenceDiagram
    participant U as Flutter Client
    participant L as SQLite queue
    participant H as Host
    U->>L: Commit commandId + payload + provisional state
    L-->>U: PENDING_LOCAL persisted
    Note over U,L: Offline interval
    U->>H: Same CommandEnvelope
    H-->>U: ACCEPTED receipt + cursor
    U->>L: Atomic apply receipt and confirmed delta
    L-->>U: ACCEPTED + confirmed state
```

## 3. Network failure after commit (unknown result)

```mermaid
sequenceDiagram
    participant U as Client
    participant H as Host
    participant D as DB
    U->>H: post_invoice(id=K)
    H->>D: COMMIT invoice + stock + ledger + receipt(K)
    Note over H,U: Connection drops before response
    U->>U: UNKNOWN_RESULT (do not create new ID)
    U->>H: GET receipt(K)
    H->>D: read stored receipt
    H-->>U: ACCEPTED(K), original officialNumber
```

## 4. Business conflict and recovery

```mermaid
sequenceDiagram
    participant A as Client A
    participant B as Client B
    participant H as Host
    A->>H: Sell 10 from available 15
    H-->>A: ACCEPTED (remaining 5)
    B->>H: Sell 10 from same stock
    H-->>B: CONFLICT / INSUFFICIENT_STOCK
    B->>B: NEEDS_RESOLUTION; display explanation
    B->>H: New corrected command ID if user accepts
```

## 5. Multi-module atomic post

```mermaid
sequenceDiagram
    participant C as Client
    participant H as Host Coordinator
    participant S as Sales Module
    participant I as Inventory Module
    participant A as Accounting Module
    participant D as DB Unit of Work
    C->>H: sales.post_invoice
    H->>D: BEGIN
    H->>S: Check sales document
    H->>I: Reserve/deduct stock in shared transaction
    H->>A: Prepare balanced journal in same transaction
    H->>D: invoice + movements + journal + receipt + outbox
    alt all valid
        H->>D: COMMIT
        H-->>C: ACCEPTED
    else invariant or database error
        H->>D: ROLLBACK
        H-->>C: REJECTED or RETRY_LATER
    end
```

These are target protocols, **not deployed or benchmarked implementations**.
