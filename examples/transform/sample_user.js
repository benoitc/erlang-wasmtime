// A tenant's transform: enrich an order event and drop test orders.
export function transform(event) {
  if (event.type !== "order") return event;
  if (event.customer && event.customer.startsWith("test-")) return null;
  const total = event.items.reduce((sum, i) => sum + i.qty * i.price, 0);
  return {
    ...event,
    total,
    tier: total > 100 ? "gold" : "standard",
    tags: [...(event.tags || []), "enriched"],
  };
}
