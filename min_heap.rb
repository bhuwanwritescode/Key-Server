class MinHeap
    def initialize
      @arr = []
      @index_map = {} 
    end
  
    def peek
      @arr[0]
    end
  
    def push(ts, key)
      if @index_map.key?(key)
        update(key, ts)
        return
      end
      @arr << [ts, key]
      idx = @arr.size - 1
      @index_map[key] = idx
      sift_up(idx)
    end
  
    def pop
      return nil if @arr.empty?
      top = @arr[0]
      remove_at(0)
      top
    end
  
    def remove(key)
      return unless @index_map.key?(key)
      remove_at(@index_map[key])
    end
  
    def update(key, new_ts)
      idx = @index_map[key]
      return unless idx
      old_ts = @arr[idx][0]
      @arr[idx][0] = new_ts
      if new_ts < old_ts
        sift_up(idx)
      else
        sift_down(idx)
      end
    end
  
    private
  
    def swap(i, j)
      @arr[i], @arr[j] = @arr[j], @arr[i]
      @index_map[@arr[i][1]] = i
      @index_map[@arr[j][1]] = j
    end
  
    def sift_up(i)
      while i > 0
        parent = (i - 1) / 2
        break if @arr[parent][0] <= @arr[i][0]
        swap(i, parent)
        i = parent
      end
    end
  
    def sift_down(i)
      n = @arr.size
      loop do
        l = 2 * i + 1
        r = 2 * i + 2
        smallest = i
        smallest = l if l < n && @arr[l][0] < @arr[smallest][0]
        smallest = r if r < n && @arr[r][0] < @arr[smallest][0]
        break if smallest == i
        swap(i, smallest)
        i = smallest
      end
    end
  
    def remove_at(i)
      last = @arr.size - 1
      key = @arr[i][1]
      if i == last
        @arr.pop
        @index_map.delete(key)
        return
      end
      swap(i, last)
      @arr.pop
      @index_map.delete(key)
      sift_up(i)
      sift_down(i)
    end
  end