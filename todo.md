- [ ] Finish encapsulating BigDecimal
- [ ] Amount = Quantity + Commodity
      ledger/src/amount.cc:994 is where they parse amounts/commodities
- [ ] account:sub-account £100 correctly parses the amount - it should error because there's not enough spaces



Here's my thinking: for most commands, we don't need to create anything other than the account tree.
