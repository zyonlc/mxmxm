export type TaxSummaryInvoice = {
  issue_date: string;
  currency_code: string;
  subtotal: number;
  tax_amount: number;
  status: "draft" | "sent" | "paid" | "overdue" | "void";
};

export type TaxSummaryExpense = {
  expense_date: string;
  currency_code: string;
  amount: number;
  tax_amount: number;
  payment_status: "paid" | "unpaid" | "refunded";
  tax_treatment: "deductible" | "non_deductible" | "review";
};

export const calculateBooksTaxSummary = (
  invoices: TaxSummaryInvoice[],
  expenses: TaxSummaryExpense[],
  currency: string,
  periodStart: string,
  periodEnd: string,
) => {
  const includedInvoiceStatuses = new Set(["sent", "overdue", "paid"]);
  const periodInvoices = invoices.filter((invoice) =>
    invoice.currency_code.trim() === currency
    && invoice.issue_date >= periodStart
    && invoice.issue_date <= periodEnd
    && includedInvoiceStatuses.has(invoice.status),
  );
  const periodExpenses = expenses.filter((expense) =>
    expense.currency_code.trim() === currency
    && expense.expense_date >= periodStart
    && expense.expense_date <= periodEnd
    && expense.payment_status !== "refunded",
  );

  return {
    invoiceIncome: periodInvoices.reduce((total, invoice) => total + Number(invoice.subtotal), 0),
    invoiceTax: periodInvoices.reduce((total, invoice) => total + Number(invoice.tax_amount), 0),
    allowableDeductions: periodExpenses
      .filter((expense) => expense.tax_treatment === "deductible")
      .reduce((total, expense) => total + Number(expense.amount), 0),
    nonDeductibleExpenses: periodExpenses
      .filter((expense) => expense.tax_treatment === "non_deductible")
      .reduce((total, expense) => total + Number(expense.amount), 0),
    expensesToReview: periodExpenses.filter((expense) => expense.tax_treatment === "review").length,
    expenseTax: periodExpenses.reduce((total, expense) => total + Number(expense.tax_amount), 0),
  };
};
