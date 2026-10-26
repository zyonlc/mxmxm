import { describe, expect, it } from "vitest";
import { calculateBooksTaxSummary } from "./booksTaxSummary";

describe("calculateBooksTaxSummary", () => {
  it("separates invoice tax from income and only counts classified deductions", () => {
    const summary = calculateBooksTaxSummary(
      [
        { issue_date: "2026-01-10", currency_code: "UGX", subtotal: 1000, tax_amount: 180, status: "paid" },
        { issue_date: "2026-02-10", currency_code: "UGX", subtotal: 500, tax_amount: 90, status: "sent" },
        { issue_date: "2026-02-11", currency_code: "UGX", subtotal: 999, tax_amount: 0, status: "draft" },
      ],
      [
        { expense_date: "2026-01-20", currency_code: "UGX", amount: 200, tax_amount: 36, payment_status: "paid", tax_treatment: "deductible" },
        { expense_date: "2026-02-20", currency_code: "UGX", amount: 300, tax_amount: 54, payment_status: "unpaid", tax_treatment: "non_deductible" },
        { expense_date: "2026-03-20", currency_code: "UGX", amount: 400, tax_amount: 72, payment_status: "paid", tax_treatment: "review" },
      ],
      "UGX",
      "2026-01-01",
      "2026-12-31",
    );

    expect(summary).toEqual({
      invoiceIncome: 1500,
      invoiceTax: 270,
      allowableDeductions: 200,
      nonDeductibleExpenses: 300,
      expensesToReview: 1,
      expenseTax: 162,
    });
    expect(summary.invoiceIncome - summary.allowableDeductions).toBe(1300);
  });

  it("keeps dates, currencies, void invoices, and refunded expenses out of the summary", () => {
    const summary = calculateBooksTaxSummary(
      [
        { issue_date: "2025-12-31", currency_code: "UGX", subtotal: 100, tax_amount: 0, status: "paid" },
        { issue_date: "2026-01-01", currency_code: "USD", subtotal: 200, tax_amount: 0, status: "paid" },
        { issue_date: "2026-06-01", currency_code: "UGX", subtotal: 300, tax_amount: 0, status: "void" },
      ],
      [
        { expense_date: "2026-06-01", currency_code: "UGX", amount: 400, tax_amount: 0, payment_status: "refunded", tax_treatment: "deductible" },
      ],
      "UGX",
      "2026-01-01",
      "2026-12-31",
    );

    expect(summary.invoiceIncome).toBe(0);
    expect(summary.allowableDeductions).toBe(0);
    expect(summary.expensesToReview).toBe(0);
  });
});
