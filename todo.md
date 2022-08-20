- [ ] Merge Ast's xact_decl and xact_body

- [ ] Amount = Quantity + Commodity
      ledger/src/amount.cc:994 is where they parse amounts/commodities
- [ ] account:sub-account £100 correctly parses the amount - it should error because there's not enough spaces


Here's my thinking: for most commands, we don't need to create anything other than the account tree.

Could we store everything for Accounts out of band? The AccountTree could be generic over a type which we store in a HashMap(usize, T). We could store Amounts, ArrayLists of Amounts (for budgeting) etc in there.


If we see a keyword where we expect an identifier, treat it as such.
We could also only check for keywords if it is the first id on a line (i.e. it's at the start of the line or it's only preceded by whitespace)

The problem I'm having at the moment is that some strings that should be tokenized as identifiers are identified as keywords instead. 
Things can be a keyword when they start from the beginning of a line, or when they're indented following a parent keyword (e.g. alias follows account indented).
