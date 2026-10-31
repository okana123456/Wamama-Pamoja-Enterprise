# Authorized product-deposit transfers

The scheduled repayment job intentionally excludes `pre_loan_deposit` funds. These funds are reserved for future product purchases and are not automatically available for existing-loan instalments.

Install `wamama-authorized-product-deposit-transfer.sql`. In Loan Deposits & Product Deposits, management can select a reserved product deposit and authorize a partial transfer to an unpaid instalment on the same client's active loan. The server restricts execution to active admins, CEOs and branch managers, within their business. Existing menu access restrictions still apply. The reason, actor, amount, source and resulting repayment are retained in a private audit ledger. Retries with the same request reference cannot debit twice. The unused balance remains a product deposit. The generated repayment starts with `Auto-deducted`, so the movement is not new cash collected.

Nancy's diagnosis on 31 October 2026 showed two pending product deposits of KES 1,300 each on 23 October, no original repayment links, and KES 189.06 unpaid on the cooking-oil loan (KES 184.06 after reporting tolerance). Ten recent scheduled job runs succeeded. Do not describe this as a failed scheduled-job run or assume the two entries are duplicates.

After installation, `wamama-nancy-authorized-deposit-correction.sql` applies KES 189.06 from one specified deposit, preserving both original records. It refuses a changed loan or a transfer above what is currently due. Expected immediate result if records are unchanged: approved paid 522.67, unpaid due 0, remaining loan balance 5749.33, combined product deposits 2410.94. These are expected values, not production results until the user runs the file.
