- [ ] Amount = Quantity + Commodity
      ledger/src/amount.cc:994 is where they parse amounts/commodities
- [ ] account:sub-account £100 correctly parses the amount - it should error because there's not enough spaces
- [ ] Make everything take a []const u8 rather than a []u8.


Here's my thinking: for most commands, we don't need to create anything other than the account tree.

Could we store everything for Accounts out of band? The AccountTree could be generic over a type which we store in a HashMap(usize, T). We could store Amounts, ArrayLists of Amounts (for budgeting) etc in there.
