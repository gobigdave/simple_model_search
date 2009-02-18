# DND: See http://wiki.rubyonrails.org/rails/pages/TextSearch for more info
#
# Adds search method to ActiveRecord::Base.
# The query language supports the operators
# (), not, and, or
# Precedence in that order.
# - is an alias for not.
# If no operator is present, and is assumed.
# Lastly, anything within double quotes is treated as 
# a single search term.
#
# For example,
#  ruby rails => records where both ruby and rails appear
#  "ruby on rails" => records where "ruby on rails" appears
#  ruby or rails => records where ruby or rails (or both) appears
#  ruby or chunky bacon => records where ruby appears or both chunky and bacon appear
#  not dead or alive => records where alive appears or dead is absent
#  -(ruby or rails) => records where neither ruby nor rails appears
#  (ruby or rails) -"ruby on rails" => records where ruby or rails appears but not the phrase "ruby on rails"
#
# Query feature by Nate McNamara (nate@mcnamara.net)
# Original TextSearch library by Duane Johnson.

module ActiveRecord
  class Base
    # Allow the user to set the default searchable fields
    def self.searches_on(*args)
      if not args.empty? and args.first != :all
        @searchable_fields = args.collect { |f| self.table_name + "." + f.to_s }
      end
    end

    # Return the default set of fields to search on
    def self.searchable_fields(tables = nil)

      # If the model has declared what it searches_on, then use that...
      if @searchable_fields.nil?
        # ... otherwise, use all text/varchar fields as the default
        fields = []
        string_columns = self.columns.select { |c| c.type == :text or c.type == :string }
        fields = string_columns.collect { |c| self.table_name + "." + c.name }
      else
        fields = @searchable_fields
      end

      # Handle include tables
      tables ||= []
      if not tables.empty?
        tables.each do |table|
          klass = eval table.to_s.classify
          fields += klass.searchable_fields([])
        end
      end

      return fields
    end

    # Search the model's text and varchar fields
    #   text = a set of words to search for
    #   :only => an array of fields in which to search for the text;
    #     default is 'all text or string columns'
    #   :except => an array of fields to exclude
    #     from the default searchable columns
    #   :include => an array of tables to include in the joins.  Fields that
    #     have searchable text will automatically be included in the default
    #     set of :search_columns.
    #   :join_include => an array of tables to include in the joins, but only
    #     for joining. (Searchable fields will not automatically be included.)
    #   :conditions => a string of additional conditions (constraints)
    #   :order => sort order (order_by SQL snippet)
    #   :page => page desired. use 0 to return everything. Defaults to 1.
    #
    #   returns WillPaginate::Collection
    #
    def self.search(text = nil, options = {})
      
      # if no search criteria, then nothing to return
      return WillPaginate::Collection.new(1, self.per_page, 0) if text.blank? || text.length <= 1
      
      # Setup the search fields
      fields = searchable_fields(options[:include])
      fields &= options[:only]   if options[:only]
      fields -= options[:except] if options[:except]

      # build search_options
      condition_list = []
      unless text.nil?
        condition_list << build_text_condition(fields, text)
      end
      if options[:conditions]
        condition_list << "#{options[:conditions]}"
      end
      conditions = condition_list.join " AND " 
      includes = (options[:include] || []) + (options[:join_include] || [])
      page = (options[:page] || 1).to_i
      find_all = options.delete(:find_all) || false
      search_options = { :include => includes.empty? ? nil : includes,
                         :conditions => conditions.empty? ? nil : conditions,
                         :order => options[:order],
                         :per_page => options[:per_page] }
                         
      # Do the search
      if page <= 0
        search_options.delete(:per_page)
        arr = find(:all, search_options)
        results = WillPaginate::Collection.create(1, arr.size > 0 ? arr.size : self.per_page, arr.size) do |pager|
          pager.replace(arr)
          pager.total_entries = arr.size unless pager.total_entries
        end
      else
        results = paginate(search_options.merge(:page => page))
      end
      results
    end

    # Given a field or array of fields, return a sql string using text
    def self.build_text_condition(fields, text)
      build_tc_from_tree(fields, demorganize(parse(text.downcase.strip_punctuation)))
    end

    private

    # A chunk is a string of non-whitespace,
    # except that anything inside double quotes
    # is a chunk, including whitespace
    def self.make_chunks(s)
      chunks = []
      while s.length > 0
        next_interesting_index = (s =~ /\s|\"/)
        if next_interesting_index
          if next_interesting_index > 0
            chunks << s[0...next_interesting_index]
            s = s[next_interesting_index..-1]
          else
            if s =~ /^\"/
              s = s[1..-1]
              next_interesting_index = (s =~ /[\"]/)
              if next_interesting_index
                chunks << s[0...next_interesting_index]
                s = s[next_interesting_index+1..-1]
              elsif s.length > 0
                chunks << s
                s = ''
              end
            else
              next_interesting_index = (s =~ /\S/)
              s = s[next_interesting_index..-1]
            end
          end
        else
          chunks << s
          s = ''
        end
      end

      # DND: process the chunks to remove whitespace
      chunks.map! { |chunk| chunk.strip_extra_whitespace }
    end

    def self.process_chunk(chunk)
      case chunk
      when /^-/
        if chunk.length == 1
          [:not]
        else
          [:not, *process_chunk(chunk[1..-1])]
        end
      when /^\+/
        if chunk.length == 1
          [:and]
        else
          [:and, *process_chunk(chunk[1..-1])]
        end
      when /^\(.*\)$/
        if chunk.length == 2
          [:left_paren, :right_paren]
       else          
          [:left_paren].concat(process_chunk(chunk[1..-2])) << :right_paren
        end
      when /^\(/
        if chunk.length == 1
          [:left_paren]
        else
          [:left_paren].concat(process_chunk(chunk[1..-1]))
        end
      when /\)$/
        if chunk.length == 1
          [:right_paren]
        else
          process_chunk(chunk[0..-2]) << :right_paren
        end
      when 'and'
        [:and]
      when 'or'
        [:or]
      when 'not'
        [:not]
      when /^(\w|(#{String::ARTICLE_WORDS.join('|')}))$/    # DND: Remove articles and single characters
        [nil]
      else
        [chunk]
      end
    end

    def self.lex(s)
      tokens = []
      make_chunks(s).each { |chunk| tokens.concat(process_chunk(chunk)) }
      tokens.compact
    end

    def self.parse_paren_expr(tokens)
      expr_tokens = []
      while !tokens.empty? && tokens[0] != :right_paren
        expr_tokens << tokens.shift
      end

      if !tokens.empty?
        tokens.shift
      end
      
      parse_expr(expr_tokens)
    end

    def self.parse_term(tokens)
      if tokens.empty?
        return ''
      end

      token = tokens.shift
      case token
      when :not
        [:not, parse_term(tokens)]
      when :left_paren
        parse_paren_expr(tokens)
      when :right_paren
        '' # skip bogus token
      when :and
        '' # skip bogus token
      when :or
        '' # skip bogus token
      else
        token
      end
    end

    def self.parse_and_expr(tokens, operand)
      if (tokens[0] == :and)
        tokens.shift
      end
      # Even if :and is missing, :and is implicit
      [:and, operand, parse_term(tokens)]
    end

    def self.parse_or_expr(tokens, operand)
      if (tokens[0] == :or)
        tokens.shift
        [:or, operand, parse_expr(tokens)]
      else
        parse_and_expr(tokens, operand)
      end
    end

    def self.parse_expr(tokens)
      if tokens.empty?
        return ''
      end

      expr = parse_term(tokens)
      while !tokens.empty?
        expr = parse_or_expr(tokens, expr)
      end

      expr
    end

    def self.parse_tokens(tokens)
      tree = parse_expr(tokens)
      tree.kind_of?(Array)? tree : [tree]
    end

    def self.parse(text)
      parse_tokens(lex(text))
    end

    def self.apply_demorgans(tree)
      if tree == []
        return []
      end
      
      token = tree.kind_of?(Array)? tree[0] : tree
      case token
      when :not
          if (tree[1].kind_of?(Array))
            subtree = tree[1]
            if subtree[0] == :and
                [:or, apply_demorgans([:not, subtree[1]]), apply_demorgans([:not, subtree[2]])]
            elsif tree[1][0] == :or
                [:and, apply_demorgans([:not, subtree[1]]), apply_demorgans([:not, subtree[2]])]
            else
              # assert tree[1][0] == :not
              apply_demorgans(subtree[1])
            end
          else
            tree
          end
      when :and
          [:and, apply_demorgans(tree[1]), apply_demorgans(tree[2])]
      when :or
          [:or, apply_demorgans(tree[1]), apply_demorgans(tree[2])]
      else
        tree
      end
    end

    def self.demorganize(tree)
      result = apply_demorgans(tree)
      result.kind_of?(Array)? result : [result]
    end

    def self.sql_escape(s)
      s.gsub('%', '\%').gsub('_', '\_')
    end

    def self.compound_tc(fields, tree)
      '(' +
        build_tc_from_tree(fields, tree[1]) +
        ' ' + tree[0].to_s + ' ' +
        build_tc_from_tree(fields, tree[2]) +
      ')'
    end

    def self.build_tc_from_tree(fields, tree)
      token = tree.kind_of?(Array)? tree[0] : tree
      case token
      when :and
        compound_tc(fields, tree)
      when :or
        compound_tc(fields, tree)
      when :not
        # assert tree[1].kind_of?(String)
        "(" +
        fields.map { |f| "(#{f} is null or #{f} not like #{sanitize('%'+sql_escape(tree[1])+'%')})" }.join(" and ") +
        ")"
      else
        "(" +
        fields.map { |f| "#{f} like #{sanitize('%'+sql_escape(token)+'%')}" }.join(" or ") +
        ")"
      end
    end

  end
end

