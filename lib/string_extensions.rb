class String

  # Replace punctuation characters with space
  def strip_punctuation
    self.gsub(/[^a-zA-Z0-9\&\+\-\"\'\s]/, ' ').strip
  end
  def strip_punctuation!
    self.replace(self.strip_punctuation)
  end
  
  # Strip all the extra whitespace
  def strip_extra_whitespace
    self.gsub(/\s+/,' ').strip
  end
  def strip_extra_whitespace!
    self.replace(self.strip_extra_whitespace)
  end
  
end